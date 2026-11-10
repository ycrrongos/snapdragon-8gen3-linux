#!/bin/bash
# Run as root on Debian: flash daily|debug boot to slot B and activate B.
set -euo pipefail
DIR=/var/lib/cerro-dualboot
BY=/dev/block/by-name
VARIANT="${1:-daily}"
BOOT="$DIR/linux-${VARIANT}.img"
VB="$DIR/vendor_boot-stock.img"
[[ $(id -u) -eq 0 ]] || { echo "need root" >&2; exit 1; }
[[ -f "$BOOT" && -f "$VB" ]] || { echo "missing $BOOT or $VB" >&2; exit 2; }
echo "=== cerro: set Linux variant=$VARIANT on slot B ==="
dd if="$BOOT" of="$BY/boot_b" bs=4M status=progress conv=fsync
dd if="$VB" of="$BY/vendor_boot_b" bs=4M status=progress conv=fsync
dd if=/dev/zero of="$BY/dtbo_b" bs=1M count=1 status=none conv=fsync 2>/dev/null || true
if [[ -x "$DIR/abctl" ]]; then "$DIR/abctl" --set_active 1 || true
elif [[ -x /usr/bin/qbootctl ]]; then qbootctl -s 1 || true
fi
sync
echo "OK: rebooting to Linux ($VARIANT)"
reboot
