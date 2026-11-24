#!/usr/bin/env bash
# Build the Test #25 Linux kernel and device tree.
set -euo pipefail
kernel="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="$(realpath -m -- "${KERNEL_OBJ:-$kernel/out-zpd1203}")"
firmware_dir="$(realpath -e -- "${HIMAX_FIRMWARE_DIR:?Set HIMAX_FIRMWARE_DIR to the directory containing the stock Himax blobs}")"
test -f "$firmware_dir/Himax_firmware.bin"
test -f "$firmware_dir/Himax_firmware_e.bin"
test -f "$kernel/drivers/kernelsu/Kconfig" || {
    echo "Run git submodule update --init and use the pinned KernelSU checkout." >&2
    exit 1
}
args=(-C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
      "KCFLAGS=-Wno-error -Wno-unused-but-set-variable -Wno-array-bounds -Wno-misleading-indentation -Wno-format -Wno-enum-conversion -Wno-gnu-variable-sized-type-not-at-end -Wno-unaligned-access -Wno-strict-prototypes")
make "${args[@]}" zpd1203_test25_defconfig
"$kernel/scripts/config" --file "$output/.config" --set-str EXTRA_FIRMWARE_DIR "$firmware_dir"
make "${args[@]}" olddefconfig
make "${args[@]}" -j"${JOBS:-$(nproc)}" Image.gz mediatek/mt6768-zpd1203-minimal.dtb
