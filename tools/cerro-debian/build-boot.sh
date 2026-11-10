#!/usr/bin/env bash
# Rebuild the proven Cerro Image with the native-Debian switch_root selector.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINUX_DIR="$PROJECT_DIR/build/linux"
BOOT_DIR="$PROJECT_DIR/build/boot_repack"
BASE_BOOT="${1:-$BOOT_DIR/boot-v2-disp-dpu-s5gb.img}"
OUTPUT_BOOT="${2:-$BOOT_DIR/boot-v2-disp-dpu-s5gb-debian.img}"
INIT_SOURCE="$PROJECT_DIR/tools/cerro-init/init"
BT_SOURCE="$PROJECT_DIR/tools/cerro-bt-up.sh"
BT_UNIT_SOURCE="$PROJECT_DIR/tools/cerro-bt.service"
CELLULAR_META_SOURCE="$PROJECT_DIR/tools/cerro-cellular-meta.sh"
CELLULAR_META_HELPER_SOURCE="$PROJECT_DIR/tools/cerro-qmi-dms-set-meta.py"
CELLULAR_META_UNIT_SOURCE="$PROJECT_DIR/tools/cerro-cellular-meta.service"
CELLULAR_PREP_SOURCE="$PROJECT_DIR/tools/cerro-cellular-prepare.sh"
CELLULAR_PREP_UNIT_SOURCE="$PROJECT_DIR/tools/cerro-cellular-prepare.service"
MODEMMANAGER_ORDER_SOURCE="$PROJECT_DIR/tools/cerro-modemmanager-order.conf"
PDMAP_STAGE_SOURCE="$PROJECT_DIR/tools/cerro-pdmap-stage.sh"
PDMAP_STAGE_UNIT_SOURCE="$PROJECT_DIR/tools/cerro-pdmap-stage.service"
PDMAP_STAGE_ORDER_SOURCE="$PROJECT_DIR/tools/cerro-pdmap-stage-order.conf"
AUDIO_SESSION_SOURCE="$PROJECT_DIR/notes/alsa-ucm-sm8650-cerro/cerro-audio-session.sh"
MEMSHARE_SOURCE_DIR="$PROJECT_DIR/patches/cellular-memshare"
MEMSHARE_MODULE="$MEMSHARE_SOURCE_DIR/qcom-memshare.ko"
INITRAMFS_SOURCE="$LINUX_DIR/usr/cerro-initramfs.cpio.gz"
CERRO_DTB="$LINUX_DIR/arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb"
CERRO_EARLY_DTB="$LINUX_DIR/arch/arm64/kernel/sm8650-nubia-cerro.dtb"

for REQUIRED_FILE in \
  "$BASE_BOOT" "$INIT_SOURCE" "$BT_SOURCE" "$BT_UNIT_SOURCE" \
  "$CELLULAR_META_SOURCE" "$CELLULAR_META_HELPER_SOURCE" \
  "$CELLULAR_META_UNIT_SOURCE" "$CELLULAR_PREP_SOURCE" \
  "$CELLULAR_PREP_UNIT_SOURCE" "$MODEMMANAGER_ORDER_SOURCE" \
  "$PDMAP_STAGE_SOURCE" "$PDMAP_STAGE_UNIT_SOURCE" \
  "$PDMAP_STAGE_ORDER_SOURCE" \
  "$AUDIO_SESSION_SOURCE" "$INITRAMFS_SOURCE" \
  "$MEMSHARE_SOURCE_DIR/Makefile" \
  "$MEMSHARE_SOURCE_DIR/qcom_memshare.c" \
  "$MEMSHARE_SOURCE_DIR/heap_mem_ext_v01.c" \
  "$MEMSHARE_SOURCE_DIR/heap_mem_ext_v01.h"; do
  [[ -f "$REQUIRED_FILE" ]] || { echo "missing: $REQUIRED_FILE" >&2; exit 1; }
done

STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/boot" "$STAGING_DIR/initramfs" "$STAGING_DIR/verify"

unpack_bootimg --boot_img "$BASE_BOOT" --out "$STAGING_DIR/boot" >/dev/null

(
  cd "$STAGING_DIR/initramfs"
  gzip -dc "$INITRAMFS_SOURCE" | cpio -idm --quiet
)
install -m 0755 "$INIT_SOURCE" "$STAGING_DIR/initramfs/init"
install -m 0755 "$BT_SOURCE" "$STAGING_DIR/initramfs/cerro-bt-up.sh"
install -m 0644 "$BT_UNIT_SOURCE" "$STAGING_DIR/initramfs/cerro-bt.service"
install -m 0755 "$CELLULAR_META_SOURCE" "$STAGING_DIR/initramfs/cerro-cellular-meta.sh"
install -m 0755 "$CELLULAR_META_HELPER_SOURCE" "$STAGING_DIR/initramfs/cerro-qmi-dms-set-meta.py"
install -m 0644 "$CELLULAR_META_UNIT_SOURCE" "$STAGING_DIR/initramfs/cerro-cellular-meta.service"
install -m 0755 "$CELLULAR_PREP_SOURCE" "$STAGING_DIR/initramfs/cerro-cellular-prepare.sh"
install -m 0644 "$CELLULAR_PREP_UNIT_SOURCE" "$STAGING_DIR/initramfs/cerro-cellular-prepare.service"
install -m 0644 "$MODEMMANAGER_ORDER_SOURCE" "$STAGING_DIR/initramfs/cerro-modemmanager-order.conf"
install -m 0755 "$PDMAP_STAGE_SOURCE" "$STAGING_DIR/initramfs/cerro-pdmap-stage.sh"
install -m 0644 "$PDMAP_STAGE_UNIT_SOURCE" "$STAGING_DIR/initramfs/cerro-pdmap-stage.service"
install -m 0644 "$PDMAP_STAGE_ORDER_SOURCE" "$STAGING_DIR/initramfs/cerro-pdmap-stage-order.conf"
rm -f "$STAGING_DIR/initramfs/cerro-qboot-mark-success.sh"
rm -f "$STAGING_DIR/initramfs/cerro-qbootctl-debian-native.conf"
mkdir -p "$STAGING_DIR/initramfs/ucm-stage"
install -m 0755 "$AUDIO_SESSION_SOURCE" "$STAGING_DIR/initramfs/ucm-stage/cerro-audio-session.sh"
: >"$STAGING_DIR/initramfs/cerro-userland-debian"

KERNEL_RELEASE=$(make -s -C "$LINUX_DIR" ARCH=arm64 LLVM=1 kernelrelease)
if [[ "${REUSE_MEMSHARE_KO:-0}" == "1" && -f "$MEMSHARE_MODULE" ]] && \
   [[ "$(modinfo -F vermagic "$MEMSHARE_MODULE")" == "$KERNEL_RELEASE "* ]] && \
   [[ "$(modinfo -F depends "$MEMSHARE_MODULE")" == "qmi_helpers" ]]; then
  echo "reusing memshare module: $MEMSHARE_MODULE (vermagic ok)"
else
  make -C "$LINUX_DIR" M="$MEMSHARE_SOURCE_DIR" ARCH=arm64 LLVM=1 \
    -j"$(nproc)" modules
  [[ -f "$MEMSHARE_MODULE" ]] || {
    echo "missing built memshare module: $MEMSHARE_MODULE" >&2
    exit 1
  }
  [[ "$(modinfo -F vermagic "$MEMSHARE_MODULE")" == "$KERNEL_RELEASE "* ]] || {
    echo "memshare module vermagic mismatch" >&2
    exit 1
  }
  [[ "$(modinfo -F depends "$MEMSHARE_MODULE")" == "qmi_helpers" ]] || {
    echo "unexpected memshare module dependency set" >&2
    exit 1
  }
fi
mkdir -p "$STAGING_DIR/initramfs/usr/lib/modules/$KERNEL_RELEASE/extra"
install -m 0644 "$MEMSHARE_MODULE" \
  "$STAGING_DIR/initramfs/usr/lib/modules/$KERNEL_RELEASE/extra/qcom-memshare.ko"
depmod -b "$STAGING_DIR/initramfs" "$KERNEL_RELEASE"
grep -q '^extra/qcom-memshare\.ko:.*qmi_helpers\.ko' \
  "$STAGING_DIR/initramfs/usr/lib/modules/$KERNEL_RELEASE/modules.dep"

if [[ ! -f "$INITRAMFS_SOURCE.pmos-s5gb" ]]; then
  cp -a "$INITRAMFS_SOURCE" "$INITRAMFS_SOURCE.pmos-s5gb"
fi
(
  cd "$STAGING_DIR/initramfs"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --null -o -H newc --owner=0:0 --quiet | gzip -9n
) >"$INITRAMFS_SOURCE"

gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout init 2>/dev/null | \
  grep -q "cerro_userland=debian"
gzip -dc "$INITRAMFS_SOURCE" | cpio -it --quiet 2>/dev/null | \
  grep -qx 'cerro-userland-debian'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-bt-up.sh 2>/dev/null | \
  grep -q 'public-addr'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-bt.service 2>/dev/null | \
  grep -q 'After=.*bluetooth.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-cellular-meta.sh 2>/dev/null | \
  grep -q 'qrtr-lookup'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-qmi-dms-set-meta.py 2>/dev/null | \
  grep -q '0x0069'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-cellular-meta.service 2>/dev/null | \
  grep -q 'Before=cerro-cellular-prepare.service ModemManager.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-cellular-prepare.service 2>/dev/null | \
  grep -q 'Requires=.*cerro-cellular-meta.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-modemmanager-order.conf 2>/dev/null | \
  grep -q 'Requires=cerro-cellular-prepare.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-pdmap-stage.sh 2>/dev/null | \
  grep -q 'mount -t vfat -o ro,nosuid,nodev,noexec'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-pdmap-stage.service 2>/dev/null | \
  grep -q 'Before=pd-mapper.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout cerro-pdmap-stage-order.conf 2>/dev/null | \
  grep -q 'Requires=cerro-pdmap-stage.service'
gzip -dc "$INITRAMFS_SOURCE" | cpio -i --to-stdout ucm-stage/cerro-audio-session.sh 2>/dev/null | \
  grep -qE 'PROFILE_SPEAKER=.*HiFi|set-card-profile.*HiFi'
gzip -dc "$INITRAMFS_SOURCE" | cpio -it --quiet 2>/dev/null | \
  grep -qx "usr/lib/modules/$KERNEL_RELEASE/extra/qcom-memshare.ko"
gzip -dc "$INITRAMFS_SOURCE" | \
  cpio -i --to-stdout "usr/lib/modules/$KERNEL_RELEASE/modules.dep" 2>/dev/null | \
  grep -q '^extra/qcom-memshare\.ko:.*qmi_helpers\.ko'
if gzip -dc "$INITRAMFS_SOURCE" | cpio -it --quiet 2>/dev/null | \
    grep -Eq '^(cerro-qboot-mark-success\.sh|cerro-qbootctl-debian-native\.conf)$'; then
  echo "unauthorized qboot mark-success payload present in initramfs" >&2
  exit 1
fi

rm -f \
  "$LINUX_DIR/usr/initramfs_data.cpio" \
  "$LINUX_DIR/usr/initramfs_inc_data" \
  "$LINUX_DIR/usr/initramfs_data.o"
make -C "$LINUX_DIR" ARCH=arm64 LLVM=1 -j"$(nproc)" \
  qcom/sm8650-nubia-cerro.dtb

[[ -f "$CERRO_DTB" ]] || { echo "missing rebuilt DTB: $CERRO_DTB" >&2; exit 1; }
install -m 0644 "$CERRO_DTB" "$CERRO_EARLY_DTB"
cmp "$CERRO_DTB" "$CERRO_EARLY_DTB"
rm -f "$CERRO_EARLY_DTB.o"
make -C "$LINUX_DIR" ARCH=arm64 LLVM=1 -j"$(nproc)" Image

python3 - "$LINUX_DIR/arch/arm64/boot/Image" "$CERRO_DTB" \
  "$STAGING_DIR/kernel-dtb-bsspad.raw" <<'PY'
import struct
import sys

image_path, dtb_path, output_path = sys.argv[1:]
image = open(image_path, "rb").read()
dtb = open(dtb_path, "rb").read()
image_size = struct.unpack_from("<Q", image, 0x10)[0]
if image_size < len(image):
    raise SystemExit(f"bad arm64 Image size: header={image_size} file={len(image)}")
with open(output_path, "wb") as output:
    output.write(image)
    output.write(b"\0" * (image_size - len(image)))
    output.write(dtb)
print(f"kernel_blob={image_size + len(dtb)} image={len(image)} dtb={len(dtb)}")
PY

CMDLINE='ignore_loglevel pd_ignore_unused clk_ignore_unused console=ttyMSM0,115200n8 earlycon=qcom_geni,0x0089c000 pmos_boot_uuid=0ad60230-638c-49c0-9c95-ab8938f81eaf pmos_root_uuid=ab3a863b-512a-447e-a35c-e681ce0ae61b pmos_rootfsopts=defaults cerro_userland=debian'
mkbootimg \
  --header_version 2 --pagesize 4096 \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --tags_offset 0x100 --dtb_offset 0x01f00000 \
  --kernel "$STAGING_DIR/kernel-dtb-bsspad.raw" \
  --ramdisk "$STAGING_DIR/boot/ramdisk" \
  --dtb "$CERRO_DTB" \
  --cmdline "$CMDLINE" \
  --os_version 16.0.0 --os_patch_level 2026-07 \
  -o "$OUTPUT_BOOT"

unpack_bootimg --boot_img "$OUTPUT_BOOT" --out "$STAGING_DIR/verify" \
  --format=mkbootimg | tee "$STAGING_DIR/verify/mkbootimg-args.txt"
grep -q "cerro_userland=debian" "$STAGING_DIR/verify/mkbootimg-args.txt"
cmp "$CERRO_DTB" "$STAGING_DIR/verify/dtb"

BOOT_SIZE=$(stat -c %s "$OUTPUT_BOOT")
if (( BOOT_SIZE > 536870912 )); then
  echo "output exceeds 512 MiB boot partition: $BOOT_SIZE" >&2
  exit 1
fi

sha256sum \
  "$OUTPUT_BOOT" \
  "$LINUX_DIR/arch/arm64/boot/Image" \
  "$INITRAMFS_SOURCE" \
  "$MEMSHARE_MODULE" \
  "$CERRO_EARLY_DTB" \
  "$STAGING_DIR/verify/dtb"
echo "native Debian boot image: $OUTPUT_BOOT ($BOOT_SIZE bytes)"
