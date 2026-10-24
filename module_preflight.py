#!/usr/bin/env python3
"""Prepare Android-compatible kernel module loading metadata for piano.

The kernel source lists are inputs only; generated metadata lives in OUT_DIR.
"""

import argparse
import os
from pathlib import Path
import re
import stat
import tempfile


LOAD_LISTS = (
    "vendor_boot.modules.load",
    "vendor_boot.modules.load.recovery",
    "vendor_dlkm.modules.load",
    "system_dlkm.modules.load",
)
MODULE_FILE = re.compile(r"[A-Za-z0-9_.+-]+\.ko\Z")
MODULE_NAME = re.compile(r"[A-Za-z0-9_.+-]+\Z")


class MetadataError(ValueError):
    pass


def parse_load_list(path: Path):
    modules = []
    seen = {}
    duplicates = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        name = line.strip()
        if not name or name.startswith("#"):
            continue
        if not MODULE_FILE.fullmatch(name):
            raise MetadataError(f"{path}:{line_no}: invalid module filename {name!r}")
        if name in seen:
            duplicates.append((line_no, name, seen[name]))
        else:
            seen[name] = line_no
            modules.append(name)
    if not modules:
        raise MetadataError(f"{path}: module load list is empty")
    return modules, duplicates


def normalize_softdeps(path: Path):
    normalized = []
    repaired = 0
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        words = line.split()
        if not words or words[0].startswith("#"):
            normalized.append(line)
            continue
        location = f"{path}:{line_no}"
        if len(words) < 3 or words[0] != "softdep" or not MODULE_NAME.fullmatch(words[1]):
            raise MetadataError(f"{location}: invalid softdep directive: {line!r}")
        tokens = words[2:]
        if tokens[0] not in ("pre:", "post:"):
            # depmod emits MODULE_SOFTDEP("ecb") as `softdep cifs ecb`;
            # Android libmodprobe needs a qualified section.
            if any(token in ("pre:", "post:") or ":" in token for token in tokens):
                raise MetadataError(f"{location}: mixed or malformed softdep sections: {line!r}")
            tokens.insert(0, "pre:")
            repaired += 1
        prior_sections = set()
        section = None
        section_members = 0
        for token in tokens:
            if token in ("pre:", "post:"):
                if section is not None and section_members == 0:
                    raise MetadataError(f"{location}: empty {section} section: {line!r}")
                if token in prior_sections or (token == "pre:" and "post:" in prior_sections):
                    raise MetadataError(f"{location}: invalid softdep section order: {line!r}")
                prior_sections.add(token)
                section = token
                section_members = 0
            elif not MODULE_NAME.fullmatch(token) or ":" in token:
                raise MetadataError(f"{location}: invalid softdep module {token!r}")
            else:
                section_members += 1
        if not section_members:
            raise MetadataError(f"{location}: empty {section} section: {line!r}")
        normalized.append("softdep " + words[1] + " " + " ".join(tokens))
    return "\n".join(normalized) + ("\n" if normalized else ""), repaired


def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    old_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
        os.chmod(temporary, old_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_lists(source: Path, target: Path):
    if source.resolve() == target.resolve():
        raise MetadataError("load-list output directory must differ from kernel source")
    prepared = {}
    for filename in LOAD_LISTS:
        prepared[filename] = parse_load_list(source / filename)
    # Validate every source before writing any generated file.
    for filename, (modules, duplicates) in prepared.items():
        atomic_write(target / filename, "\n".join(modules) + "\n")
        print(f"   [preflight] {filename}: {len(modules)} modules, {len(duplicates)} duplicates removed")
        for line, module, first in duplicates[:5]:
            print(f"   [preflight]   {module}: line {line} repeats line {first}")
        if len(duplicates) > 5:
            print(f"   [preflight]   ... and {len(duplicates) - 5} further repeats")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    lists = commands.add_parser("load-lists", help="normalize all partition load lists")
    lists.add_argument("source", type=Path, help="kernel build_config/piano directory")
    lists.add_argument("target", type=Path, help="build output directory for normalized lists")
    softdeps = commands.add_parser("softdeps", help="repair and validate depmod modules.softdep")
    softdeps.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "load-lists":
            load_lists(args.source, args.target)
        else:
            content, repaired = normalize_softdeps(args.file)
            if content != args.file.read_text(encoding="utf-8"):
                atomic_write(args.file, content)
            print(f"   [preflight] {args.file}: repaired {repaired} unqualified softdep entries")
    except (OSError, UnicodeError, MetadataError) as exc:
        parser.exit(1, f"[error] module preflight: {exc}\n")


if __name__ == "__main__":
    main()
