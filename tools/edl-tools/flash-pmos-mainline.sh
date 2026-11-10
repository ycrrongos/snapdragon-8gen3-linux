#!/usr/bin/env bash
# Flash mainline pmOS boot chain via EDL (9008).
# Fixes: vendor_boot carries mainline DTB (ABL ignores Image-appended DTB on GKI),
# erase dtbo, unlock ABL, boot+logdump+userdata.
set -euo pipefail
cd "$(dirname "$0")"
LOADER="$(pwd)/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$(pwd)/venv/bin/python3"
BACKUP="$(pwd)/pmos-flash/backup-20260806-020517"
FLASH="$(pwd)/pmos-flash"
WORKDIR=/mnt/data/LOA_Nubia_Z60U/build/boot_repack
BOOT="$WORKDIR/boot-v4-mainline.img"
VB="$WORKDIR/vendor_boot-mainline.img"
PMOS_BOOT=/mnt/data/LOA_Nubia_Z60U/build/out/nubia-cerro-boot.img
PMOS_ROOT=/mnt/data/LOA_Nubia_Z60U/build/out/nubia-cerro-root.img
ABL="/mnt/data/LOA_Nubia_Z60U/中兴家族工具箱1.2.8-beta4/bin/res/PQ83A01/abl_unlock.elf"
EDL() { sudo -E "$PY" edl/edl.py --loader="$LOADER" "$@"; }

lsusb | grep -q 9008 || { echo 'need 9008'; exit 1; }
BUS=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\1/p')
DEVN=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\2/p')
sudo chmod 666 "/dev/bus/usb/$BUS/$DEVN"

# backup vendor_boot/dtbo once
mkdir -p "$BACKUP"
for p in vendor_boot_a vendor_boot_b dtbo_a dtbo_b; do
  if [ ! -f "$BACKUP/${p}.img" ]; then
    echo "==== backup $p ===="
    EDL r "$p" "$BACKUP/${p}.img"
  fi
done

echo '==== unlock abl ===='
EDL w abl_a "$ABL"
EDL w abl_b "$ABL"

echo '==== boot + vbmeta ===='
for s in a b; do
  EDL w "boot_${s}" "$BOOT"
  EDL w "vbmeta_${s}" "$FLASH/vbmeta.img"
  EDL w "vbmeta_system_${s}" "$FLASH/vbmeta_system.img"
  EDL w "vendor_boot_${s}" "$VB"
  EDL e "dtbo_${s}"
  EDL e "init_boot_${s}"
done

echo '==== pmOS partitions ===='
EDL w logdump "$PMOS_BOOT"
EDL w userdata "$PMOS_ROOT"

echo '==== reset ===='
EDL reset || true
echo DONE
