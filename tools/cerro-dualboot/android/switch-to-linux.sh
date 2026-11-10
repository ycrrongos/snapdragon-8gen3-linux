#!/system/bin/sh
# Run as root on Android (KernelSU): switch to Linux daily (default) or debug.
# Images: /data/cerro-dualboot/{linux-daily.img,linux-debug.img,vendor_boot-stock.img}
set -eu
DIR=/data/cerro-dualboot
VARIANT="${1:-daily}"
BOOT="$DIR/linux-${VARIANT}.img"
VB="$DIR/vendor_boot-stock.img"
BY=/dev/block/by-name

if [ "$(id -u)" != 0 ]; then
  echo "ERROR: need root (su)" >&2
  exit 1
fi
if [ ! -f "$BOOT" ] || [ ! -f "$VB" ]; then
  echo "ERROR: missing $BOOT or $VB — push images first" >&2
  exit 2
fi

echo "=== cerro: Android → Linux ($VARIANT) ==="
# Prefer slot B for Linux; write both boot slots for reliability when bootctl HAL missing
for s in boot_b boot_a; do
  echo "dd $BOOT → $s"
  dd if="$BOOT" of="$BY/$s" bs=4M status=none conv=fsync
done
for s in vendor_boot_b vendor_boot_a; do
  echo "dd stock vendor_boot → $s"
  dd if="$VB" of="$BY/$s" bs=4M status=none conv=fsync
done
# erase dtbo (mainline uses builtin DTB; stock dtbo fights us)
for s in dtbo_a dtbo_b; do
  echo "erase $s"
  dd if=/dev/zero of="$BY/$s" bs=1M count=1 status=none conv=fsync 2>/dev/null || true
done

# Try HAL bootctl; fall back to misc / reboot and hope B is preferred after andiradulescu abctl later
if [ -x /system/bin/bootctl ]; then
  /system/bin/bootctl set-active-boot-slot 1 2>/dev/null || true
fi
if [ -x /data/adb/ksu/bin/bootctl ]; then
  /data/adb/ksu/bin/bootctl set-active-boot-slot 1 2>/dev/null || true
fi
if [ -x "$DIR/abctl" ]; then
  "$DIR/abctl" --set_active 1 2>/dev/null || true
fi

echo "OK: rebooting to Linux ($VARIANT)"
sync
reboot
