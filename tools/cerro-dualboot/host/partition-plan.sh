#!/usr/bin/env bash
# Print GPT resize plan for cerro: userdata 200GiB + cerro_linux remainder.
# Sector size on this device: 4096 bytes (from sgdisk probe 2026-10-14).
set -euo pipefail
SECTOR=4096
USERDATA_GIB="${USERDATA_GIB:-200}"
# From live probe: userdata starts at sector 3302184, disk last usable 124002298
START=3302184
LAST=124002298
BYTES_PER_GIB=$((1024*1024*1024))
USERDATA_SECTORS=$(( USERDATA_GIB * BYTES_PER_GIB / SECTOR ))
# align to 2-sector boundary (device uses align-2)
align2() { echo $(( ($1 + 1) / 2 * 2 )); }
USERDATA_END=$(align2 $((START + USERDATA_SECTORS - 1)))
LINUX_START=$(align2 $((USERDATA_END + 1)))
LINUX_SECTORS=$((LAST - LINUX_START + 1))
LINUX_GIB=$(awk -v s="$LINUX_SECTORS" -v b="$SECTOR" 'BEGIN{printf "%.1f", s*b/1024/1024/1024}')

cat <<EOF
Cerro repartition plan (do NOT run blindly — execute inside OrangeFox)
  sector_size=$SECTOR
  userdata: number=12 start=$START end=$USERDATA_END  (~${USERDATA_GIB} GiB)
  cerro_linux: number=13 start=$LINUX_START end=$LAST (~${LINUX_GIB} GiB)

Suggested OrangeFox / adb shell sequence:
  sgdisk --backup=/tmp/sda-gpt.bak /dev/block/sda
  umount /data 2>/dev/null || true
  e2fsck -fy /dev/block/by-name/userdata   # skip if f2fs
  resize.f2fs -t $((USERDATA_END - START + 1)) /dev/block/by-name/userdata
  sgdisk /dev/block/sda --delete=12
  sgdisk /dev/block/sda --new=12:$START:$USERDATA_END --change-name=12:userdata --typecode=12:A03A
  sgdisk /dev/block/sda --new=13:$LINUX_START:$LAST --change-name=13:cerro_linux --typecode=13:8300
  sgdisk --randomize-guids /dev/block/sda
  mke2fs -t ext4 -L cerro_linux /dev/block/by-name/cerro_linux
EOF
