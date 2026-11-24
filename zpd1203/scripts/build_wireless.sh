#!/usr/bin/env bash
# Build MT6768 connectivity modules against an already built ZPD1203 kernel.
set -euo pipefail

project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${WSL_BUILD_DIR:-$HOME/mt6768_build}"
kernel="${KERNEL_SRC:-$build/src}"
obj="${KERNEL_OBJ:-$build/out}"
top="${WIRELESS_DIR:-$build/wireless-uhas34.29}"
ext="$top/connectivity"
result="${OUT_DIR:-$project/out/wireless}"
modules="$result/modules"
args=(O="$obj" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION="${LOCALVERSION-}"
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
      "KCFLAGS=-Wno-error -Wno-unused-but-set-variable -Wno-array-bounds -Wno-format -Wno-strict-prototypes -Wno-enum-conversion -Wno-misleading-indentation -Wno-unaligned-access -I$kernel/net/wireless")
jobs="${JOBS:-$(nproc)}"

# Source manifest: Motorola Mobility MMI-UHAS34.29-3 for MT6768.
while read -r dir revision; do
    if [[ "$(git -C "$ext/$dir" rev-parse HEAD)" != "$revision" ]]; then
        echo "Unexpected revision in $ext/$dir, expected $revision" >&2
        exit 1
    fi
done <<'PINS'
common 8c858eae50cbbb9b86008038f7b124761506baaf
bt/mt66xx 2a851b310d43afd104a0379e552c23a58eef69ab
connfem b40ab0fd746016c6a8d6f2d55ae9c98edc797981
wlan/adaptor 6c5a97726c86d1cf6da6d38387b6b2abe118a0ea
wlan/core/gen4m f72d1f101aae82da581add5e4cf87d52f5174c0f
PINS

cd "$kernel"
test -s "$obj/vmlinux.symvers"
release="$(cat "$obj/include/config/kernel.release")"
layout_crc="$(awk '$2 == "module_layout" {print $1}' "$obj/vmlinux.symvers")"
test -n "$layout_crc"
mkdir -p "$modules" "$top/vendor/mediatek/kernel_modules"
if [[ ! -e "$top/vendor/mediatek/kernel_modules/connectivity" ]]; then
    ln -s "$ext" "$top/vendor/mediatek/kernel_modules/connectivity"
fi
make -j"$jobs" "${args[@]}" modules_prepare > "$result/modules-prepare.log" 2>&1
test "$(cat "$obj/include/config/kernel.release")" = "$release"
cp "$obj/vmlinux.symvers" "$obj/Module.symvers"

build_module() {
    local name="$1"
    local target="$2"
    local module_path="$3"
    shift 3
    local log="$result/$name-build.log"
    if ! make -j"$jobs" "${args[@]}" M="$target" TOP="$top" "$@" modules > "$log" 2>&1; then
        tail -n 60 "$log"
        return 1
    fi

    local vermagic crc
    vermagic="$(modinfo -F vermagic "$module_path")"
    crc="$(modprobe --show-modversions "$module_path" | awk '$2 == "module_layout" {print $1}')"
    if [[ "${vermagic%% *}" != "$release" || "$crc" != "$layout_crc" ]]; then
        echo "ABI mismatch for $module_path, vermagic=$vermagic module_layout=$crc" >&2
        return 1
    fi
    cp "$module_path" "$modules/"
    printf '%s %s module_layout=%s depends=%s\n' "$(basename "$module_path")" \
        "$release" "$crc" "$(modinfo -F depends "$module_path")"
}

build_module btif drivers/misc/mediatek/btif "$obj/drivers/misc/mediatek/btif/common/btif_drv.ko"
build_module cfg80211 net/wireless "$obj/net/wireless/cfg80211.ko"
build_module connfem "$ext/connfem" "$ext/connfem/connfem.ko"
build_module conn_md drivers/misc/mediatek/conn_md "$obj/drivers/misc/mediatek/conn_md/conn_md_drv.ko"
build_module connadp drivers/misc/mediatek/connectivity "$obj/drivers/misc/mediatek/connectivity/connadp.ko" \
    CONFIG_MTK_COMBO=m

platform_symvers="$obj/drivers/misc/mediatek/btif/Module.symvers $obj/drivers/misc/mediatek/conn_md/Module.symvers $obj/drivers/misc/mediatek/connectivity/Module.symvers"
build_module wmt "$ext/common" "$ext/common/wmt_drv.ko" CONFIG_MTK_COMBO=m \
    MTK_PLATFORM_WMT=MT6768 TARGET_BOARD_PLATFORM_WMT=mt6768 KBUILD_EXTRA_SYMBOLS="$platform_symvers"
build_module bt "$ext/bt/mt66xx/wmt" "$ext/bt/mt66xx/wmt/bt_drv_connac1x.ko" \
    BT_PLATFORM=connac1x BT_ENABLE_LOW_POWER_DEBUG=y 'LOG_TAG=[BT_Drv][wmt]' \
    KBUILD_EXTRA_SYMBOLS="$ext/common/Module.symvers"
build_module wlan-adaptor "$ext/wlan/adaptor" "$ext/wlan/adaptor/wmt_chrdev_wifi.ko" \
    CONNAC_VER=1_0 MODULE_NAME=wmt_chrdev_wifi KBUILD_EXTRA_SYMBOLS="$ext/common/Module.symvers"

gen4m_patch="$project/kernel/patches/wireless/0001-gen4m-select-available-display-notifier.patch"
if ! git -C "$ext/wlan/core/gen4m" apply --reverse --check "$gen4m_patch" 2>/dev/null; then
    git -C "$ext/wlan/core/gen4m" apply "$gen4m_patch"
fi
git -C "$ext/wlan/core/gen4m" diff --check
build_module gen4m "$ext/wlan/core/gen4m" "$ext/wlan/core/gen4m/wlan_drv_gen4m.ko" \
    CONFIG_MTK_COMBO_WIFI_HIF=axi MODULE_NAME=wlan_drv_gen4m MTK_COMBO_CHIP=CONNAC WLAN_CHIP_ID=6768 \
    MTK_ANDROID_WMT=y WIFI_ENABLE_GCOV= WIFI_IP_SET=1 MTK_ANDROID_EMI=y MTK_WLAN_SERVICE=yes \
    KBUILD_EXTRA_SYMBOLS="$platform_symvers $ext/connfem/Module.symvers $ext/common/Module.symvers $ext/wlan/adaptor/Module.symvers $obj/net/wireless/Module.symvers"
