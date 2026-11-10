#!/usr/bin/env bash
# Lower-level Cerro debug (bringup §5.14): dump USB/role/typec/dmesg to a path
# that survives ACM death. Prefer /var/log on live Debian; also try pmOS boot
# UUID if that partition is still around (EDL pull).
set -euo pipefail
OUT_DIR="${1:-/var/log}"
mkdir -p "$OUT_DIR"
TS=$(date -Iseconds 2>/dev/null || date)
{
  echo "==== CERRO USB DIAG $TS uptime=$(cut -d. -f1 /proc/uptime) ===="
  echo "cmdline: $(tr '\0' ' ' </proc/cmdline)"
  uname -a
  echo "--- usb_role ---"
  for d in /sys/class/usb_role/*; do
    [ -e "$d/role" ] && echo "$(basename "$d")=$(cat "$d/role")"
  done
  echo "--- typec ---"
  ls /sys/class/typec 2>&1 || true
  for p in /sys/class/typec/port*; do
    [ -d "$p" ] || continue
    echo "PORT=$(basename "$p")"
    for f in data_role power_role port_type preferred_role; do
      [ -e "$p/$f" ] && echo "  $f=$(cat "$p/$f")"
    done
  done
  echo "--- udc ---"; ls -la /sys/class/udc 2>&1 || true
  echo "--- gadget ---"; ls /sys/kernel/config/usb_gadget 2>&1 || true
  echo "--- lsusb (host) ---"; lsusb 2>&1 || true
  echo "--- dmesg usb/dwc/typec/xhci ---"
  dmesg 2>/dev/null | grep -iE 'usb|dwc3|gadget|udc|typec|ucsi|xhci|role' | tail -120 || true
  echo "--- dmesg tail ---"
  dmesg 2>/dev/null | tail -40 || true
  echo "==== END ===="
} >"$OUT_DIR/cerro-usb-diag.txt" 2>&1
dmesg >"$OUT_DIR/cerro-dmesg.txt" 2>/dev/null || true
sync
echo "wrote $OUT_DIR/cerro-usb-diag.txt"
# Optional historic pull path (pmOS boot UUID from early dualboot)
BOOT_UUID=0ad60230-638c-49c0-9c95-ab8938f81eaf
if command -v blkid >/dev/null && part=$(blkid --uuid "$BOOT_UUID" 2>/dev/null); then
  mp=$(mktemp -d)
  if mount -o rw "$part" "$mp" 2>/dev/null; then
    cp -f "$OUT_DIR/cerro-usb-diag.txt" "$OUT_DIR/cerro-dmesg.txt" "$mp/" 2>/dev/null || true
    sync
    umount "$mp" 2>/dev/null || true
    echo "also copied to pmOS boot $part"
  fi
  rmdir "$mp" 2>/dev/null || true
fi
