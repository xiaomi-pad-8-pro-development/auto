# Kernel build script for the Xiaomi Pad 8 Pro (piano)

Builds the [alxp kernel](https://github.com/xiaomi-pad-8-pro-development/android_kernel_xiaomi_piano) into the [prebuilts](https://github.com/xiaomi-pad-8-pro-development/android_device_xiaomi_piano-kernel).

```
ROM_DIR=~/android/<rom> ./build.sh          # plain, branch 6.6
ROM_DIR=~/android/<rom> KSU=1 ./build.sh    # KernelSU-Next + SUSFS, branch 6.6-ksu
```

| Output | What |
| --- | --- |
| `Image` | Kernel |
| `dtb/`, `dtbo.img` | Devicetrees with techpack overlays merged |
| `modules/` | vendor_boot, vendor_dlkm, system_dlkm |
| `kernel-headers/` | UAPI headers |

Needs clang `r510928` and a ROM checkout. `COMMIT=1` commits to the prebuilt repo.

Details: [docs/DETAILS.md](docs/DETAILS.md)
