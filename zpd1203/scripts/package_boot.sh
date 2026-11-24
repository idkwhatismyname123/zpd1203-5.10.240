#!/usr/bin/env bash
# Package an Android boot.img (header v2) compatible with MT6768 ZYB ZPD1203 stock LK.
# Matches verified stock boot_a.img parameters from firmware-analysis/boot_structure.json.
# Run in WSL2.
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
KERNEL_IMG="${KERNEL_IMG:-$OUT_DIR/Image.gz}"
DTB_RAW="${DTB_RAW:-$OUT_DIR/mt6768-zpd1203-minimal.dtb}"
RAMDISK_IMG="${RAMDISK_IMG:-$OUT_DIR/initramfs-minimal.cpio.gz}"
OUT_BOOT="${OUT_BOOT:-$OUT_DIR/boot-mt6768-5.10.img}"
CMDLINE="${CMDLINE:-bootopt=64S3,32N2,64N2 buildvariant=user console=tty0 8250.nr_uarts=2 cpuidle.off=1 printk.devkmsg=on ignore_loglevel loglevel=8 clk_ignore_unused pd_ignore_unused regulator_ignore_unused fbcon=rotate:2 fbcon=font:TER16x32}"
ADD_AVB_FOOTER="${ADD_AVB_FOOTER:-1}"
PARTITION_SIZE="${PARTITION_SIZE:-33554432}" # 0x2000000 from MT6768_Android_scatter.txt

if [ ! -f "$KERNEL_IMG" ]; then
  echo "ERROR: kernel image not found: $KERNEL_IMG" >&2
  exit 1
fi
if [ ! -f "$DTB_RAW" ]; then
  echo "ERROR: raw DTB not found: $DTB_RAW" >&2
  exit 1
fi
if [ ! -f "$RAMDISK_IMG" ]; then
  echo "ERROR: ramdisk not found: $RAMDISK_IMG" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# Wrap raw FDT into Android DT Table (0xd7b7ab1e) exactly like stock boot_a.img
DTB_WRAPPED="$OUT_DIR/dtb.dtimg"
python3 "$ROOT/tools/wrap_dt_table.py" "$DTB_RAW" "$DTB_WRAPPED" --page-size 2048 --id 0 --rev 0

# Verified stock boot_a.img header v2 layout:
#   base=0x40000000, kernel_offset=0x00080000 -> 0x40080000
#   ramdisk_offset=0x07c80000 -> 0x47c80000
#   tags_offset=0x0bc80000    -> 0x4bc80000
#   dtb_offset=0x0bc80000     -> 0x4bc80000
#   pagesize=2048, os_version=12.0.0, os_patch_level=2024-07 (raw 0x18000187)
RAW_BOOT="${OUT_BOOT%.img}.raw.img"
mkbootimg \
  --header_version 2 \
  --pagesize 2048 \
  --base 0x40000000 \
  --kernel_offset 0x00080000 \
  --ramdisk_offset 0x07c80000 \
  --second_offset 0x00000000 \
  --tags_offset 0x0bc80000 \
  --dtb_offset 0x0bc80000 \
  --os_version 12.0.0 \
  --os_patch_level 2024-07 \
  --cmdline "$CMDLINE" \
  --kernel "$KERNEL_IMG" \
  --ramdisk "$RAMDISK_IMG" \
  --dtb "$DTB_WRAPPED" \
  -o "$RAW_BOOT"

cp "$RAW_BOOT" "$OUT_BOOT"

if [ "$ADD_AVB_FOOTER" = "1" ] && command -v avbtool >/dev/null 2>&1; then
  avbtool add_hash_footer \
    --image "$OUT_BOOT" \
    --partition_name boot \
    --partition_size "$PARTITION_SIZE" \
    --hash_algorithm sha256
  echo "Added unsigned AVB hash footer (partition_size=$PARTITION_SIZE) to $OUT_BOOT"
fi

echo "Packaged:"
ls -lh "$RAW_BOOT" "$OUT_BOOT"
sha256sum "$RAW_BOOT" "$OUT_BOOT"
