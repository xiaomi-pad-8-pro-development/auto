#!/usr/bin/env bash

set -e

# Builds the alxp kernel for the Xiaomi Pad 8 Pro (piano) and lays the result
# out as device/xiaomi/piano-kernel: Image, dtb/, dtbo.img, kernel-headers/
# and modules/{vendor_boot,vendor_dlkm,system_dlkm}.
#
# Every path can be overridden from the environment; the defaults expect
#   ~/kernel/android_kernel_xiaomi_piano    kernel source
#   ~/kernel/clang-r510928                  the clang stock was built with
#   ~/android/<rom>                         a ROM checkout for mkdtboimg.py and
#                                           kernel-build-tools
### configuration

ROOT_DIR="${ROOT_DIR:-${HOME}/kernel}"
KERNEL_DIR="${KERNEL_DIR:-${ROOT_DIR}/android_kernel_xiaomi_piano}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
DEFCONFIG="piano_defconfig"
# KSU=1 builds the root variant: KernelSU-Next with SUSFS.
if [ "${KSU:-0}" = 1 ]; then
    CONFIG_FRAGMENTS="piano_ksu.config"
    VARIANT="ksu"
    PREBUILT_BRANCH="seventeen-ksu"
else
    CONFIG_FRAGMENTS=""
    VARIANT="plain"
    PREBUILT_BRANCH="seventeen"
fi

ROM_DIR="${ROM_DIR:?set ROM_DIR to a ROM checkout}"
PREBUILT_KERNEL_DIR="${PREBUILT_KERNEL_DIR:-${ROM_DIR}/device/xiaomi/piano-kernel}"
mkdir -p "${PREBUILT_KERNEL_DIR}"

# Release prebuilts have separate branches for plain and rooted images. Catch
# an incorrect checkout before the final sync deletes/replaces its contents.
if [ -e "${PREBUILT_KERNEL_DIR}/.git" ]; then
    CURRENT_BRANCH="$(git -C "${PREBUILT_KERNEL_DIR}" symbolic-ref --quiet --short HEAD || true)"
    if [ "${CURRENT_BRANCH}" != "${PREBUILT_BRANCH}" ]; then
        echo "[error] ${VARIANT} requires prebuilt branch ${PREBUILT_BRANCH}, found ${CURRENT_BRANCH:-detached HEAD}" >&2
        exit 1
    fi
fi

# Use the source commit's date rather than the wall clock so rebuilds of the
# same revision carry the same version and embedded header timestamps.
export LC_ALL=C
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${KERNEL_DIR}" log -1 --format=%ct)}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%a %b %d %H:%M:%S UTC %Y')}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-alxp}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-piano}"

# The clang stock was built with, plus pahole and friends from the ROM.
LLVM_DIR="${LLVM_DIR:-${ROOT_DIR}/clang-r510928/bin}/"
export PATH="${ROM_DIR}/prebuilts/kernel-build-tools/linux-x86/bin:${PATH}"
# LOCALVERSION= keeps the release at the defconfig's -alxp, without the +
# setlocalversion adds for a git tree.
TOOL_ARGS=(ARCH=arm64 LLVM="${LLVM_DIR}" LLVM_IAS=1 O="${OUT_DIR}" LOCALVERSION=)
STRIP_BIN="${LLVM_DIR}llvm-strip"
MKDTBOIMG="${ROM_DIR}/system/libufdt/utils/src/mkdtboimg.py"

# The techpack overlays are merged into the base and board devicetrees with
# Qualcomm's merge_dtbs.py, which needs fdtoverlaymerge from their dtc.
MERGE_DTBS="$(cd "$(dirname "$0")" && pwd)/merge_dtbs.py"
DTC_DIR="${ROOT_DIR}/dtc"
DTC_REPO="https://git.codelinaro.org/clo/la/kernel_platform/external/dtc.git"
DTC_REV="6aa78bad656ffc106bb909774fee5fc2d86d4949"

# Module lists kept with the kernel source.
BUILD_CONFIG_DIR="${KERNEL_DIR}/build_config/piano"
VB_LIST="${BUILD_CONFIG_DIR}/vendor_boot.modules.load"
VB_RECOVERY_LIST="${BUILD_CONFIG_DIR}/vendor_boot.modules.load.recovery"
VDLKM_LIST="${BUILD_CONFIG_DIR}/vendor_dlkm.modules.load"
SDLKM_LIST="${BUILD_CONFIG_DIR}/system_dlkm.modules.load"
BLOCKLIST="${BUILD_CONFIG_DIR}/modules.blocklist"

# Normalize all four load lists before compiling. Keep the source lists
# untouched, and use exactly these ordered lists for staging and packaging.
PREFLIGHT_TOOL="$(cd "$(dirname "$0")" && pwd)/module_preflight.py"
PREFLIGHT_DIR="${OUT_DIR}/module_preflight"
echo "   [preflight] Checking and normalizing kernel module load lists..."
python3 "${PREFLIGHT_TOOL}" load-lists "${BUILD_CONFIG_DIR}" "${PREFLIGHT_DIR}"
VB_LIST="${PREFLIGHT_DIR}/vendor_boot.modules.load"
VB_RECOVERY_LIST="${PREFLIGHT_DIR}/vendor_boot.modules.load.recovery"
VDLKM_LIST="${PREFLIGHT_DIR}/vendor_dlkm.modules.load"
SDLKM_LIST="${PREFLIGHT_DIR}/system_dlkm.modules.load"

# Devicetrees, as listed for piano in platform_map.bzl.
DTB_DIR="${OUT_DIR}/arch/arm64/boot/dts/vendor/qcom"
TECHPACK_DTB_DIR="${OUT_DIR}/arch/arm64/boot/dts/techpack"
BASE_DTBS="sun.dtb sun-v2.dtb sun-tp.dtb sun-tp-v2.dtb sunp.dtb sunp-v2.dtb sunp-tp.dtb sunp-tp-v2.dtb"
BOARD_DTBOS="piano-sm8750-overlay.dtbo"

#####
#####
# tools
#####
#####

if [ ! -x "${DTC_DIR}/fdtoverlaymerge" ]; then
    echo "   [tools] Building fdtoverlaymerge..."
    rm -rf "${DTC_DIR}"
    git init -q "${DTC_DIR}"
    git -C "${DTC_DIR}" fetch -q --depth 1 "${DTC_REPO}" "${DTC_REV}"
    git -C "${DTC_DIR}" checkout -q FETCH_HEAD
    # dtc reads OUT_DIR itself, so keep ours out of its environment.
    env -u OUT_DIR make -C "${DTC_DIR}" -j"$(nproc)" NO_PYTHON=1 NO_YAML=1 dtc fdtget fdtoverlay fdtoverlaymerge >/dev/null
fi
export PATH="${DTC_DIR}:${PATH}"
# The locally built dtc tools link against libfdt in their build directory.
export LD_LIBRARY_PATH="${DTC_DIR}/libfdt${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

#####
#####
# build kernel, modules & dtbs
#####
#####

echo "========================================"
echo "Starting Kernel Build"
echo "========================================"

cd "${KERNEL_DIR}"

echo "   [build] Generating config..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" "${DEFCONFIG}" ${CONFIG_FRAGMENTS}

echo "   [build] Compiling kernel, modules and devicetrees..."
# Board overlays are bases for techpack overlays too, so export their labels.
make -j"$(nproc)" "${TOOL_ARGS[@]}" DTC_FLAGS=-@ Image modules dtbs

KERNEL_VER=$(cat "${OUT_DIR}/include/config/kernel.release")
echo "   [info] Kernel Version: ${KERNEL_VER}"

# modules_install never removes anything, so modules dropped from the
# build would otherwise keep getting shipped from earlier runs
rm -rf "${MODULES_STAGING_DIR}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

#####
#####
# sort, strip & sign modules
#####
#####

echo "========================================"
echo "Sorting & Stripping Modules"
echo "========================================"

DLKM_STAGING="${OUT_DIR}/dlkm_staging"
rm -rf "${DLKM_STAGING}"
for part in vendor_boot vendor_dlkm system_dlkm; do
    mkdir -p "${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
done

SIGN_FILE="${OUT_DIR}/scripts/sign-file"
SIGN_HASH=$(sed -n 's/^CONFIG_MODULE_SIG_HASH="\(.*\)"$/\1/p' "${OUT_DIR}/.config")
SIGN_KEY="${OUT_DIR}/certs/signing_key.pem"
SIGN_CERT="${OUT_DIR}/certs/signing_key.x509"

# every module the build produced, by file name
declare -A MODULE_PATH
while read -r module; do
    MODULE_PATH["$(basename "${module}")"]="${module}"
done < <(find "${MODULES_STAGING_DIR}" -type f -name "*.ko")

# what each module needs loaded before it, by file name, from the
# modules.dep of the build
declare -A MODULE_DEPS
while IFS=: read -r module deps; do
    names=""
    for dep in ${deps}; do
        names+=" $(basename "${dep}")"
    done
    MODULE_DEPS["$(basename "${module}")"]="${names}"
done < "${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}/modules.dep"

# the listed modules plus everything they depend on, so that a partition
# loaded on its own, like vendor_boot in first stage init, is complete
module_closure() {
    local -A seen=()
    local -a queue
    local mod dep
    read -r -a queue <<< "$(cat "$@" | awk '!seen[$0]++' | tr '\n' ' ')"
    while [ ${#queue[@]} -gt 0 ]; do
        mod="${queue[0]}"
        queue=("${queue[@]:1}")
        [ -n "${seen[${mod}]}" ] && continue
        seen["${mod}"]=1
        echo "${mod}"
        for dep in ${MODULE_DEPS[${mod}]}; do
            queue+=("${dep}")
        done
    done
}

# copy modules to a partition, stripped and signed with the key the kernel
# was built with; anything not on a list is not shipped
stage_modules() {
    local part="$1"; shift
    local dest="${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
    local mod
    for mod in "$@"; do
        if [ -z "${MODULE_PATH[${mod}]}" ]; then
            echo "   [error] ${mod} is listed for ${part} but was not built" >&2
            return 1
        fi
        cp "${MODULE_PATH[${mod}]}" "${dest}/"
        "${STRIP_BIN}" --strip-debug "${dest}/${mod}"
        "${SIGN_FILE}" "${SIGN_HASH}" "${SIGN_KEY}" "${SIGN_CERT}" "${dest}/${mod}"
    done
    echo "   [${part}] $(find "${dest}" -name "*.ko" | wc -l) modules"
}

# vendor_boot carries the recovery modules as well, since piano boots
# recovery with the vendor_boot ramdisk
stage_modules vendor_boot $(module_closure "${VB_LIST}" "${VB_RECOVERY_LIST}")
stage_modules vendor_dlkm $(cat "${VDLKM_LIST}")
stage_modules system_dlkm $(cat "${SDLKM_LIST}")

#####
#####
# generate module metadata
#####
#####

# depmod can emit bare MODULE_SOFTDEP("ecb") as "softdep cifs ecb".
# libmodprobe requires "softdep cifs pre: ecb". Validate every section and
# keep explicit pre/post ordering, failing before prebuilts are replaced.

echo "========================================"
echo "Generating Metadata"
echo "========================================"

SRC_METADATA="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}"
for part in vendor_boot vendor_dlkm system_dlkm; do
    echo "   [meta] Processing ${part}..."
    TARGET_DIR="${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
    cp "${SRC_METADATA}/modules.builtin" "${SRC_METADATA}/modules.builtin.modinfo" \
        "${SRC_METADATA}/modules.order" "${TARGET_DIR}/"
    depmod -b "${DLKM_STAGING}/${part}" "${KERNEL_VER}"
    python3 "${PREFLIGHT_TOOL}" softdeps "${TARGET_DIR}/modules.softdep"
done

cp "${VB_LIST}" "${DLKM_STAGING}/vendor_boot/lib/modules/${KERNEL_VER}/modules.load"
cp "${VB_RECOVERY_LIST}" "${DLKM_STAGING}/vendor_boot/lib/modules/${KERNEL_VER}/modules.load.recovery"
cp "${BLOCKLIST}" "${DLKM_STAGING}/vendor_boot/lib/modules/${KERNEL_VER}/modules.blocklist"
cp "${VDLKM_LIST}" "${DLKM_STAGING}/vendor_dlkm/lib/modules/${KERNEL_VER}/modules.load"
cp "${BLOCKLIST}" "${DLKM_STAGING}/vendor_dlkm/lib/modules/${KERNEL_VER}/modules.blocklist"
cp "${SDLKM_LIST}" "${DLKM_STAGING}/system_dlkm/lib/modules/${KERNEL_VER}/modules.load"

#####
#####
# vendor ramdisk fragment
#####
#####

# The first stage modules go to their own vendor ramdisk fragment. Lay it
# out like the build system lays out vendor ramdisk modules: real files in
# a flat /lib/modules, absolute paths in modules.dep, everything owned by
# root and no "." entry (that one would hand / to the build user).
echo "   [ramdisk] Creating the dlkm vendor ramdisk fragment..."
VB_SRC="${DLKM_STAGING}/vendor_boot/lib/modules/${KERNEL_VER}"
VB_RD="${OUT_DIR}/vendor_ramdisk_staging"
rm -rf "${VB_RD}"
mkdir -p "${VB_RD}/lib/modules"
cp "${VB_SRC}"/*.ko "${VB_SRC}/modules.load" "${VB_SRC}/modules.load.recovery" \
    "${VB_SRC}/modules.blocklist" "${VB_SRC}/modules.softdep" "${VB_SRC}/modules.alias" \
    "${VB_RD}/lib/modules/"
sed -E 's#([^ :]+\.ko)#/lib/modules/\1#g' "${VB_SRC}/modules.dep" > "${VB_RD}/lib/modules/modules.dep"
find "${VB_RD}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
( cd "${VB_RD}" && find . -mindepth 1 | sed 's|^\./||' | sort | cpio --reproducible -H newc -o -R 0:0 --quiet | lz4 -l -12 --favor-decSpeed > "${OUT_DIR}/dlkm.cpio" )

#####
#####
# devicetrees
#####
#####

echo "========================================"
echo "Merging Devicetrees"
echo "========================================"

DT_STAGING="${OUT_DIR}/dt_staging"
rm -rf "${DT_STAGING}"
mkdir -p "${DT_STAGING}/base" "${DT_STAGING}/techpack" "${DT_STAGING}/merged"
for dt in ${BASE_DTBS} ${BOARD_DTBOS}; do
    cp "${DTB_DIR}/${dt}" "${DT_STAGING}/base/"
done
find "${TECHPACK_DTB_DIR}" -name "*.dtbo" -exec cp {} "${DT_STAGING}/techpack/" \;

python3 "${MERGE_DTBS}" --base "${DT_STAGING}/base" --techpack "${DT_STAGING}/techpack" \
    --out "${DT_STAGING}/merged" --loglevel warn

python3 "${MKDTBOIMG}" create "${OUT_DIR}/dtbo.img" --page_size=4096 \
    $(for dt in ${BOARD_DTBOS}; do echo "${DT_STAGING}/merged/${dt}"; done)

#####
#####
# kernel headers
#####
#####

echo "========================================"
echo "Exporting Kernel Headers"
echo "========================================"

HDR_STAGING="${OUT_DIR}/hdr_staging"
rm -rf "${HDR_STAGING}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_HDR_PATH="${HDR_STAGING}" headers_install

# the techpacks export their UAPI headers next to the kernel ones
TECHPACK_DIR="${KERNEL_DIR}/techpack"
export_uapi() {
    local src="$1" dst="$2" hdr out
    [ -d "${src}" ] || return 0
    while read -r hdr; do
        out="${HDR_STAGING}/include/${dst}/${hdr#"${src}"/}"
        mkdir -p "$(dirname "${out}")"
        # headers_install.sh runs scripts/unifdef from the build directory
        ( cd "${OUT_DIR}" && "${KERNEL_DIR}/scripts/headers_install.sh" "${hdr}" "${out}" )
    done < <(find "${src}" -name "*.h")
}
export_uapi "${TECHPACK_DIR}/display-drivers/include/uapi/display" display
export_uapi "${TECHPACK_DIR}/audio-kernel/include/uapi/audio" .
export_uapi "${TECHPACK_DIR}/video-driver/include/uapi/vidc" .
export_uapi "${TECHPACK_DIR}/graphics-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/camera-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/securemsm-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/securemsm-kernel/smmu-proxy/include/uapi" .
export_uapi "${TECHPACK_DIR}/dsp-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/eva-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/synx-kernel/include/uapi" .
export_uapi "${TECHPACK_DIR}/mm-drivers/hw_fence/include/uapi" .
export_uapi "${TECHPACK_DIR}/dataipa/drivers/platform/msm/include/uapi" .

# bionic defines these itself, and the kernel versions clash with it
rm -f "${HDR_STAGING}/include/linux/sched/types.h" "${HDR_STAGING}/include/linux/eventpoll.h"

#####
#####
# sync to prebuilts
#####
#####

echo "========================================"
echo "Syncing to Prebuilts"
echo "========================================"

safe_copy() {
    if [ -f "$1" ]; then
        echo "   [sync] $(basename "$1")"
        cp -f "$1" "$2"
    else
        echo "   [WARN] missing $1"
    fi
}

# start from a clean slate, so nothing dropped from the build lingers
rm -rf "${PREBUILT_KERNEL_DIR:?}/Image" "${PREBUILT_KERNEL_DIR}/dtb" \
    "${PREBUILT_KERNEL_DIR}/dtbo.img" "${PREBUILT_KERNEL_DIR}/modules" \
    "${PREBUILT_KERNEL_DIR}/kernel-headers"
mkdir -p "${PREBUILT_KERNEL_DIR}/dtb" "${PREBUILT_KERNEL_DIR}/modules/vendor_boot" \
    "${PREBUILT_KERNEL_DIR}/modules/vendor_dlkm" "${PREBUILT_KERNEL_DIR}/modules/system_dlkm" \
    "${PREBUILT_KERNEL_DIR}/kernel-headers"

safe_copy "${OUT_DIR}/arch/arm64/boot/Image" "${PREBUILT_KERNEL_DIR}/"
for dt in ${BASE_DTBS}; do
    safe_copy "${DT_STAGING}/merged/${dt}" "${PREBUILT_KERNEL_DIR}/dtb/"
done
safe_copy "${OUT_DIR}/dtbo.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/dlkm.cpio" "${PREBUILT_KERNEL_DIR}/modules/vendor_boot/"

for part in vendor_dlkm system_dlkm; do
    echo "   [sync] ${part} modules"
    cp "${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"/*.ko \
        "${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}/modules.load" \
        "${PREBUILT_KERNEL_DIR}/modules/${part}/"
done
cp "${BLOCKLIST}" "${PREBUILT_KERNEL_DIR}/modules/vendor_dlkm/modules.blocklist"

echo "   [sync] kernel headers"
cp -r "${HDR_STAGING}/include/." "${PREBUILT_KERNEL_DIR}/kernel-headers/"
find "${PREBUILT_KERNEL_DIR}/kernel-headers" \( -name ".install" -o -name "..install.cmd" \) -delete
cat > "${PREBUILT_KERNEL_DIR}/kernel-headers/Makefile" <<EOF
VERSION = $(sed -n 's/^VERSION = *//p' "${KERNEL_DIR}/Makefile")
PATCHLEVEL = $(sed -n 's/^PATCHLEVEL = *//p' "${KERNEL_DIR}/Makefile")

headers_install:
	@mkdir -p \$(O)/usr/include
	@rsync -mrq --delete \$(shell pwd)/* \$(O)/usr/include

all:
	@true
EOF

KERNEL_HEAD=$(git -C "${KERNEL_DIR}" rev-parse --short=12 HEAD)

# COMMIT=1 records the update in the prebuilt repository.
if [ "${COMMIT:-0}" = 1 ]; then
    git -C "${PREBUILT_KERNEL_DIR}" add -A .
    git -C "${PREBUILT_KERNEL_DIR}" commit -q -m "piano-kernel: Update prebuilts $(date -u +%Y%m%d%H%M)

- Kernel: ${KERNEL_VER} (${VARIANT})
- Kernel HEAD: ${KERNEL_HEAD}"
fi

echo "========================================"
echo "Done! ${KERNEL_VER} (${VARIANT}) from ${KERNEL_HEAD}"
echo "========================================"
