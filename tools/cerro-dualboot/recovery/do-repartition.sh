#!/sbin/sh
# Run inside PBRP/TWRP (adb root). Shrinks userdata F2FS ~200GiB, creates cerro_linux ext4.
# Sector size 4096; numbers from host/partition-plan.sh defaults.
set -eu
SECTOR=4096
START=3302184
USERDATA_END=55730984
LINUX_START=55730986
LAST=124002298
SDA=/dev/block/sda
UD=/dev/block/by-name/userdata

echo "=== force unmount data ==="
twrp unmount /data 2>/dev/null || true
for m in /data /sdcard /storage/emulated /mnt/data; do
  umount -l "$m" 2>/dev/null || true
done
# drain any leftover mounts of userdata
i=0
while grep -qE 'userdata|sda12' /proc/mounts && [ "$i" -lt 10 ]; do
  mp=$(awk '/userdata|sda12/{print $2; exit}' /proc/mounts)
  [ -n "$mp" ] || break
  echo "umount $mp"
  umount -l "$mp" 2>/dev/null || umount -f "$mp" 2>/dev/null || true
  i=$((i + 1))
done
if grep -qE 'userdata|sda12' /proc/mounts; then
  echo "ERROR: still mounted:"
  grep -E 'userdata|sda12' /proc/mounts
  exit 9
fi
echo "UNMOUNTED_OK"

echo "=== GPT backup ==="
sgdisk --backup=/tmp/sda-gpt.bak "$SDA" || true

echo "=== fsck + resize.f2fs ==="
fsck.f2fs -f "$UD" || true
# -t takes sector count of the filesystem
resize.f2fs -t $((USERDATA_END - START + 1)) "$UD"

echo "=== rewrite GPT entries 12/13 ==="
sgdisk "$SDA" --delete=12 || true
sgdisk "$SDA" --new=12:$START:$USERDATA_END --change-name=12:userdata --typecode=12:A03A
sgdisk "$SDA" --new=13:$LINUX_START:$LAST --change-name=13:cerro_linux --typecode=13:8300
partprobe "$SDA" 2>/dev/null || true
sleep 2

echo "=== mkfs cerro_linux ==="
DEV13=/dev/block/sda13
[ -b "$DEV13" ] || DEV13=/dev/block/by-name/cerro_linux
mke2fs -t ext4 -F -L cerro_linux "$DEV13"

echo "OK: reboot, then restore Debian onto cerro_linux"
sgdisk --print "$SDA" | tail -25
