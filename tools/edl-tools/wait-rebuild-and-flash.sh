#!/usr/bin/env bash
# Monitor kernel rebuild, then EDL-flash boot with built-in cerro DTB.
set -euo pipefail
LOG=/tmp/cerro-monitor.log
exec > >(stdbuf -oL -eL tee -a "$LOG") 2>&1
echo "==== monitor start $(date) pid=$$ ===="

WORKDIR=/mnt/data/LOA_Nubia_Z60U/build/boot_repack
IMG=/mnt/data/LOA_Nubia_Z60U/build/linux/arch/arm64/boot/Image
DTB=/mnt/data/LOA_Nubia_Z60U/build/linux/arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb
EDL_DIR=/mnt/data/LOA_Nubia_Z60U/tools/edl-tools
STOCK_VB="$EDL_DIR/pmos-flash/backup-20260806-020517/vendor_boot_a.img"
ABL="/mnt/data/LOA_Nubia_Z60U/中兴家族工具箱1.2.8-beta4/bin/res/PQ83A01/abl_unlock.elf"
LOADER="$EDL_DIR/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PYBIN="$EDL_DIR/venv/bin/python3"
UNIT=kernel-cerro-rebuild4.service

echo "waiting for $UNIT ..."
for i in $(seq 1 480); do
  if [ -f /tmp/kernel-rebuild.done ]; then
    echo "done marker at $(date)"
    break
  fi
  st=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
  # is-active returns non-zero for inactive/failed → empty st
  [ -n "$st" ] || st=inactive
  if [ "$st" = "exited" ] || [ "$st" = "inactive" ] || [ "$st" = "failed" ]; then
    sleep 2
    if [ -f /tmp/kernel-rebuild.done ] || grep -q 'EXIT:' /tmp/kernel-rebuild.log 2>/dev/null; then
      echo "unit finished st=$st"
      break
    fi
  fi
  if (( i % 4 == 0 )); then
    usb=$(lsusb | grep -E '9008|18d1:|19d2:' || echo none)
    last=$(tail -1 /tmp/kernel-rebuild.log 2>/dev/null | tr -d '\r' | tail -c 120)
    echo "[$(date +%H:%M:%S)] build=$st usb=$usb | $last"
  fi
  sleep 15
done

if ! grep -q 'EXIT:0' /tmp/kernel-rebuild.log 2>/dev/null; then
  echo "BUILD FAILED or no EXIT:0"
  tail -50 /tmp/kernel-rebuild.log || true
  exit 1
fi
# Ignore stale EXIT:0 from a previous run: Image must contain new banner
for _ in $(seq 1 60); do
  if [ -f "$IMG" ] && strings "$IMG" | grep -q 'Using built-in cerro DTB'; then
    break
  fi
  echo "waiting for new Image with built-in DTB banner..."
  sleep 10
done
test -f "$IMG" || { echo "missing Image"; exit 1; }
if ! strings "$IMG" | grep -q 'Using built-in cerro DTB'; then
  echo "Image lacks built-in DTB banner — wrong build"
  exit 1
fi
# Verify built-in DTB string in Image
if ! strings "$IMG" | grep -q 'Using built-in cerro DTB'; then
  echo "WARNING: built-in DTB banner not found in Image (patch missing?)"
fi
ls -lh "$IMG"

mkdir -p "$WORKDIR/out"
cp -f "$IMG" "$WORKDIR/Image.raw"
# Still append DTB as secondary hint; primary is built-in
if [ -f "$DTB" ]; then
  cp -f "$DTB" "$WORKDIR/out/dtb"
  python3 <<'PY'
import struct
workdir='/mnt/data/LOA_Nubia_Z60U/build/boot_repack'
img=open(f'{workdir}/Image.raw','rb').read()
dtb=open(f'{workdir}/out/dtb','rb').read()
image_size=struct.unpack_from('<Q', img, 0x10)[0]
padded=img + b'\x00'*(image_size-len(img)) + dtb
open(f'{workdir}/Image-dtb-bsspad.raw','wb').write(padded)
print('padded', len(padded))
PY
  KERNEL_BLOB="$WORKDIR/Image-dtb-bsspad.raw"
else
  KERNEL_BLOB="$WORKDIR/Image.raw"
fi

CMDLINE='ignore_loglevel pd_ignore_unused clk_ignore_unused console=ttyMSM0,115200n8 earlycon=qcom_geni,0x0089c000 pmos_boot_uuid=0ad60230-638c-49c0-9c95-ab8938f81eaf pmos_root_uuid=ab3a863b-512a-447e-a35c-e681ce0ae61b pmos_rootfsopts=defaults'
mkbootimg --header_version 2 --pagesize 4096 \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --tags_offset 0x100 --dtb_offset 0x01f00000 \
  --kernel "$KERNEL_BLOB" \
  --ramdisk "$WORKDIR/out/ramdisk" \
  --dtb "$WORKDIR/out/dtb" \
  --cmdline "$CMDLINE" \
  --os_version 16.0.0 --os_patch_level 2026-07 \
  -o "$WORKDIR/boot-v2-builtin-dtb.img"
ls -lh "$WORKDIR/boot-v2-builtin-dtb.img"

echo "waiting for 9008..."
for i in $(seq 1 180); do
  if lsusb | grep -q 05c6:9008; then
    echo "9008 detected $(date)"
    break
  fi
  if (( i % 6 == 0 )); then
    echo "[$(date +%H:%M:%S)] no 9008: $(lsusb | grep -E '18d1:|19d2:|05c6:' || echo none)"
  fi
  sleep 5
done
lsusb | grep -q 05c6:9008 || { echo 'TIMEOUT no 9008'; exit 1; }

BUS=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\1/p')
DEVN=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\2/p')
sudo chmod 666 "/dev/bus/usb/$BUS/$DEVN"
EDL() { sudo -E "$PYBIN" "$EDL_DIR/edl/edl.py" --loader="$LOADER" "$@"; }

echo "==== flash built-in DTB boot ===="
EDL w abl_a "$ABL"
EDL w abl_b "$ABL"
for s in a b; do
  EDL w "boot_${s}" "$WORKDIR/boot-v2-builtin-dtb.img"
  EDL w "vendor_boot_${s}" "$STOCK_VB"
  EDL e "dtbo_${s}" || true
done
EDL reset || true
echo "==== ALL_DONE $(date) ===="
sleep 4
for i in 1 2 3 4 5 6 7 8 9 10 12 15 18 20; do
  echo "post $i: $(lsusb | grep -E '18d1:|05c6:|19d2:' || echo none)"
  sleep 2
done
