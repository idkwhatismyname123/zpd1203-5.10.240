# ZPD1203 Linux 5.10.240 · Test #25

Linux 5.10.240 for the ZYB ZPD1203 tablet (MediaTek MT6768/MT6769). Test #25 booted Android 12 on the device. Display in landscape, Himax touch support, ADB, Wi-Fi, Bluetooth and battery percentage were verified. The build includes KernelSU and a NEON-accelerated framebuffer bridge.

**Camera is unsupported in Test #25.** USB charging status is also incomplete.

Tested kernel release: `5.10.240-zpd1203-@idkwhatismyname123`.

## Build the kernel

Use an ARM64-capable LLVM toolchain on Linux or WSL2. The tested compiler was Clang 21.1.8. Install the standard Linux kernel build dependencies and the GNU ARM64 and ARM32 cross tools.

Provide `Himax_firmware.bin` and `Himax_firmware_e.bin` from your own stock firmware in a local directory, then run from the repository root:

```sh
git submodule update --init
HIMAX_FIRMWARE_DIR=/path/to/himax-firmware bash zpd1203/scripts/build-kernel.sh
```

The script writes `out-zpd1203/arch/arm64/boot/Image.gz` and `out-zpd1203/arch/arm64/boot/dts/mediatek/mt6768-zpd1203-minimal.dtb`.

## Build the Android boot image

The source tree includes the Android init wrapper, framebuffer bridge, and packaging scripts under `zpd1203/`. Use your own extracted stock Android 12 boot ramdisk and stock DTBO. Firmware, stock images, device logs and the flashable Test #25 image are kept out of this source repository.

The wireless script builds nine modules against the same kernel. Place the following pinned Motorola sources under `$WIRELESS_DIR/connectivity`. Each repo must be checked out at the revision listed in `zpd1203/scripts/build_wireless.sh`.

| Local path | Upstream |
| --- | --- |
| `common` | [connectivity-common](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-common) |
| `bt/mt66xx` | [connectivity-bt-mt66xx](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-bt-mt66xx) |
| `connfem` | [connectivity-connfem](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-connfem) |
| `wlan/adaptor` | [connectivity-wlan-adaptor](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-wlan-adaptor) |
| `wlan/core/gen4m` | [connectivity-wlan-core-gen4m](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-wlan-core-gen4m) |

```sh
export WIRELESS_DIR=/path/to/wireless-source
export STOCK_RD=/path/to/extracted-stock-ramdisk.gz
mkdir -p zpd1203/out
KERNEL_SRC="$PWD" KERNEL_OBJ="$PWD/out-zpd1203" bash zpd1203/scripts/build_wireless.sh
RADIO_MODULE_DIR="$PWD/zpd1203/out/wireless/modules" bash zpd1203/scripts/build_android12_ramdisk.sh
KERNEL_IMG="$PWD/out-zpd1203/arch/arm64/boot/Image.gz" \
  DTB_RAW="$PWD/out-zpd1203/arch/arm64/boot/dts/mediatek/mt6768-zpd1203-minimal.dtb" \
  RAMDISK_IMG="$PWD/zpd1203/out/ramdisk-android12-b2.cpio.gz" \
  CMDLINE='bootopt=64S3,32N2,64N2 buildvariant=user console=tty0 8250.nr_uarts=2 cpuidle.off=1 printk.devkmsg=on ignore_loglevel loglevel=8 clk_ignore_unused pd_ignore_unused regulator_ignore_unused mt6768.force_slot_a=1 androidboot.mode=normal androidboot.selinux=permissive' \
  bash zpd1203/scripts/package_boot.sh
bash zpd1203/scripts/verify_boot.sh
```

Packaging also needs `fakeroot`, `cpio`, `xz`, `kmod`, `mkbootimg` and `avbtool`. The ramdisk wrapper is intended for Android bring-up with permissive SELinux and debugging enabled.

## Source provenance

This repository contains a snapshot of Motorola Mobility's `kernel-mtk` at commit [f83ca9e95d59](https://github.com/MotorolaMobilityLLC/kernel-mtk/commit/f83ca9e95d5944053603fe7f0663fb21467eb50f) with the Test #25 ZPD1203 board port applied. KernelSU is pinned to v3.3.1 (`0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d`). See the upstream kernel `COPYING` and source-level notices.
