# ZPD1203 Linux 5.10.240

适用于 ZYB ZPD1203 平板（联发科 MT6768／MT6769）的 Linux 5.10.240 内核。已在实机启动 Android 12，并验证了横屏显示、Himax 触屏驱动、ADB、Wi-Fi、蓝牙和电量百分比。内核集成了 KernelSU，显示桥接使用 NEON 加速像素拷贝。

**相机暂不支持。** USB 充电状态的上报尚未完成。

实测内核版本为 `5.10.240-zpd1203-@idkwhatismyname123`。

## 编译内核

在 Linux 或 WSL2 下准备支持 ARM64 的 LLVM 工具链、Linux 内核编译依赖，以及 GNU ARM64 和 ARM32 交叉编译工具。实测使用的是 Clang 21.1.8。

从自己的原厂固件提取 `Himax_firmware.bin` 和 `Himax_firmware_e.bin`，放在同一目录中。在仓库根目录运行以下命令，并将固件路径替换为实际路径。

```sh
git submodule update --init
HIMAX_FIRMWARE_DIR=/path/to/himax-firmware bash zpd1203/scripts/build-kernel.sh
```

编译生成的内核位于 `out-zpd1203/arch/arm64/boot/Image.gz`，设备树位于 `out-zpd1203/arch/arm64/boot/dts/mediatek/mt6768-zpd1203-minimal.dtb`。

## 打包 Android 启动镜像

`zpd1203/` 目录包含 Android 启动包装程序、显示桥接源码和打包脚本。请使用从自己设备的原厂 Android 12 固件提取的启动初始内存盘和原厂 DTBO。仓库提供源码，原厂固件、镜像、设备日志和刷机镜像均未上传。

无线构建脚本会针对同一内核编译九个模块。把下列摩托罗拉上游仓库放到 `$WIRELESS_DIR/connectivity` 下的对应位置，并签出 `zpd1203/scripts/build_wireless.sh` 指定的提交。

| 本地路径 | 上游源码 |
| --- | --- |
| `common` | [无线公共驱动](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-common) |
| `bt/mt66xx` | [蓝牙驱动](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-bt-mt66xx) |
| `connfem` | [无线射频前端驱动](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-connfem) |
| `wlan/adaptor` | [Wi-Fi 适配层](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-wlan-adaptor) |
| `wlan/core/gen4m` | [Wi-Fi 核心驱动](https://github.com/MotorolaMobilityLLC/vendor-mediatek-kernel_modules-connectivity-wlan-core-gen4m) |

从仓库根目录运行以下命令，并替换无线源码和原厂初始内存盘的路径。

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

打包还需要 `fakeroot`、`cpio`、`xz`、`kmod`、`mkbootimg` 和 `avbtool`。启动镜像用于移植调试，启用了调试功能，并将 SELinux 设置为宽容模式。

## 源码来源

本仓库以摩托罗拉的 `kernel-mtk` 为基线，并应用了 ZPD1203 的板级移植改动。 [上游提交 f83ca9e95d59](https://github.com/MotorolaMobilityLLC/kernel-mtk/commit/f83ca9e95d5944053603fe7f0663fb21467eb50f)

KernelSU 固定为 v3.3.1（`0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d`）。许可证详见内核的 `COPYING` 和各源码文件中的声明。
