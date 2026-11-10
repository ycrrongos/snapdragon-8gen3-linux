#!/system/bin/sh
# Run as root: restore Android boot chain from /data/cerro-dualboot/android-*.img
set -eu
DIR=/data/cerro-dualboot
BY=/dev/block/by-name

need() { [ -f "$1" ] || { echo "ERROR: missing $1" >&2; exit 2; }; }
if [ "$(id -u)" != 0 ]; then
  echo "ERROR: need root" >&2
  exit 1
fi

need "$DIR/android-boot.img"
need "$DIR/android-init_boot.img"
need "$DIR/android-vendor_boot.img"
need "$DIR/android-dtbo.img"

echo "=== cerro: → Android boot chain ==="
for s in a b; do
  dd if="$DIR/android-boot.img" of="$BY/boot_$s" bs=4M status=none conv=fsync
  dd if="$DIR/android-init_boot.img" of="$BY/init_boot_$s" bs=4M status=none conv=fsync
  dd if="$DIR/android-vendor_boot.img" of="$BY/vendor_boot_$s" bs=4M status=none conv=fsync
  dd if="$DIR/android-dtbo.img" of="$BY/dtbo_$s" bs=4M status=none conv=fsync
done
if [ -f "$DIR/android-vbmeta.img" ]; then
  for s in a b; do
    dd if="$DIR/android-vbmeta.img" of="$BY/vbmeta_$s" bs=1M status=none conv=fsync
  done
fi
if [ -f "$DIR/android-vbmeta_system.img" ]; then
  for s in a b; do
    dd if="$DIR/android-vbmeta_system.img" of="$BY/vbmeta_system_$s" bs=1M status=none conv=fsync
  done
fi

if [ -x /system/bin/bootctl ]; then
  /system/bin/bootctl set-active-boot-slot 0 2>/dev/null || true
fi
if [ -x "$DIR/abctl" ]; then
  "$DIR/abctl" --set_active 0 2>/dev/null || true
fi

echo "OK: rebooting Android"
sync
reboot
