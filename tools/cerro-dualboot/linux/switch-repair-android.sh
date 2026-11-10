#!/bin/bash
# REPAIR ONLY — run as root on Debian: restore the full Android boot chain to BOTH
# slots via dd, then activate A. Only needed if slot A's boot chain got clobbered;
# normal dualboot switching is switch-to-android.sh (slot activation, no writes).
set -euo pipefail
DIR=/var/lib/cerro-dualboot
BY=/dev/block/by-name
need() { [[ -f "$1" ]] || { echo "missing $1 — place Android images in $DIR" >&2; exit 2; }; }
[[ $(id -u) -eq 0 ]] || { echo "need root" >&2; exit 1; }
need "$DIR/boot-android.img"
need "$DIR/init_boot-android.img"
need "$DIR/vendor_boot-android.img"
need "$DIR/dtbo-android.img"
echo "=== cerro REPAIR: dd Android chain to both slots, then active A ==="
for s in a b; do
  dd if="$DIR/boot-android.img" of="$BY/boot_$s" bs=4M status=progress conv=fsync
  dd if="$DIR/init_boot-android.img" of="$BY/init_boot_$s" bs=4M status=progress conv=fsync
  dd if="$DIR/vendor_boot-android.img" of="$BY/vendor_boot_$s" bs=4M status=progress conv=fsync
  dd if="$DIR/dtbo-android.img" of="$BY/dtbo_$s" bs=4M status=progress conv=fsync
done
if [[ -x "$DIR/abctl" ]]; then
  "$DIR/abctl" --set_active 0 || true
elif [[ -x /usr/bin/qbootctl ]]; then
  qbootctl -s 0 || true
fi
sync
echo "OK: rebooting to Android"
reboot
