# Kernel build script for the Xiaomi Pad 8 Pro (piano)

Builds the [alxp kernel](https://github.com/xiaomi-pad-8-pro-development/android_kernel_xiaomi_piano)
and turns it into the prebuilts in
[android_device_xiaomi_piano-kernel](https://github.com/xiaomi-pad-8-pro-development/android_device_xiaomi_piano-kernel):

| Output | What it is |
| --- | --- |
| `Image` | The kernel |
| `dtb/` | Base devicetrees with the Qualcomm techpack overlays merged in |
| `dtbo.img` | The piano board overlay, merged the same way |
| `modules/vendor_boot/dlkm.cpio` | First stage and recovery modules, as a vendor ramdisk fragment |
| `modules/vendor_dlkm/`, `modules/system_dlkm/` | The other modules with their `modules.load` |
| `kernel-headers/` | UAPI headers, including the techpack ones |

Modules are stripped and signed with the key the kernel was built with, and
each partition gets only the modules on its list in `build_config/piano`.

## Usage

```
ROM_DIR=~/android/<rom> ./build.sh
```

Set `KERNEL_DIR`, `OUT_DIR`, `LLVM_DIR` or `PREBUILT_KERNEL_DIR` to override
their defaults (see the top of `build.sh`). `COMMIT=1` commits the result in
the prebuilt repository.

Needs the kernel source, clang `r510928` (the version stock was built with),
and a ROM checkout for `mkdtboimg.py` and `kernel-build-tools`.
`fdtoverlaymerge` is built from Qualcomm's dtc on the first run.

## License

GPL-3.0. `merge_dtbs.py` is Qualcomm's, under its own license in the file.
