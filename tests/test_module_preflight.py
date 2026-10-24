#!/usr/bin/env python3
"""Source-only checks; do not invoke kernel builds or connected devices."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "module_preflight.py"
spec = importlib.util.spec_from_file_location("module_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class ModulePreflightTest(unittest.TestCase):
    def test_all_load_lists_preserve_first_order_and_remove_repeats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / "input", root / "output"
            source.mkdir()
            original = "# heading\n foo.ko\nbar-name.ko\nfoo.ko\n\nbar-name.ko\n"
            for filename in preflight.LOAD_LISTS:
                (source / filename).write_text(original, encoding="utf-8")
            preflight.load_lists(source, target)
            for filename in preflight.LOAD_LISTS:
                self.assertEqual((target / filename).read_text(), "foo.ko\nbar-name.ko\n")
                self.assertEqual((source / filename).read_text(), original)

    def test_invalid_source_rejects_all_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / "input", root / "output"
            source.mkdir()
            for filename in preflight.LOAD_LISTS:
                (source / filename).write_text("good.ko\n")
            (source / preflight.LOAD_LISTS[-1]).write_text("../../unexpected.ko\n")
            with self.assertRaises(preflight.MetadataError):
                preflight.load_lists(source, target)
            self.assertFalse(target.exists())

    def test_load_lists_refuses_in_place_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(preflight.MetadataError):
                preflight.load_lists(Path(temporary), Path(temporary))

    def test_cifs_unqualified_and_qualified_softdeps(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "modules.softdep"
            path.write_text(
                "softdep cifs ecb\nsoftdep cifs_md4 pre: md4\n"
                "softdep other pre: a b post: c\n# comment\n",
                encoding="utf-8",
            )
            content, repaired = preflight.normalize_softdeps(path)
            self.assertEqual(repaired, 1)
            self.assertEqual(
                content,
                "softdep cifs pre: ecb\nsoftdep cifs_md4 pre: md4\n"
                "softdep other pre: a b post: c\n# comment\n",
            )
            path.write_text(content)
            self.assertEqual(preflight.normalize_softdeps(path), (content, 0))

    def test_malformed_softdeps_fail_without_touching_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "modules.softdep"
            malformed = (
                "softdep cifs", "softdep cifs pre:", "softdep cifs pre: post: ecb",
                "softdep cifs pre: ecb post:", "softdep cifs ecb post: foo",
                "softdep cifs post: ecb pre: md4", "softdep cifs pre:foo",
                "softdep cifs pre: ecb pre: md4", "softdep cifs pre: ecb nonsense:",
            )
            for line in malformed:
                with self.subTest(line=line):
                    path.write_text(line + "\n")
                    with self.assertRaises(preflight.MetadataError):
                        preflight.normalize_softdeps(path)
                    self.assertEqual(path.read_text(), line + "\n")

    def test_cli_softdep_repair_and_failure_are_atomic(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "modules.softdep"
            path.write_text("softdep cifs ecb\n")
            cmd = [sys.executable, str(SCRIPT), "softdeps", str(path)]
            successful = subprocess.run(cmd, capture_output=True, text=True, check=False)
            self.assertEqual(successful.returncode, 0, successful.stderr)
            self.assertEqual(path.read_text(), "softdep cifs pre: ecb\n")
            path.write_text("softdep cifs pre:\n")
            failed = subprocess.run(cmd, capture_output=True, text=True, check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("empty pre: section", failed.stderr)
            self.assertEqual(path.read_text(), "softdep cifs pre:\n")


if __name__ == "__main__":
    unittest.main()
