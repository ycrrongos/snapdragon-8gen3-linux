#!/usr/bin/env bash
# Flash cerro boot via EDL 9008 (preferred) or fastboot.
# Fastboot commands are always timed out — sticky ABL often leaves
# `fastboot` hanging on "< waiting for any device >", which used to
# block waiters from noticing a later 9008.
set -euo pipefail
BOOT=${1:-/mnt/data/LOA_Nubia_Z60U/build/boot_repack/boot-v2-builtin-dtb.img}
STOCK_VB=/mnt/data/LOA_Nubia_Z60U/tools/edl-tools/pmos-flash/backup-20260806-020517/vendor_boot_a.img
test -f "$BOOT"

FB_TIMEOUT=${FB_TIMEOUT:-25}

fb() {
  # usage: fb <fastboot args...>
  timeout -k 3 "$FB_TIMEOUT" fastboot "$@"
}

flash_edl() {
  echo "==== via EDL 9008 (both A/B slots) ===="
  EDL_DIR=/mnt/data/LOA_Nubia_Z60U/tools/edl-tools
  LOADER="$EDL_DIR/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
  PYBIN="$EDL_DIR/venv/bin/python3"
  BUS=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\1/p')
  DEVN=$(lsusb -d 05c6:9008 | sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\2/p')
  USBDEV="/dev/bus/usb/$BUS/$DEVN"
  # ACL/udev may already grant write; avoid interactive sudo password.
  if [[ ! -w "$USBDEV" ]]; then
    if sudo -n chmod 666 "$USBDEV" 2>/dev/null; then
      :
    else
      echo "WARN: $USBDEV not writable and sudo -n failed; trying edl anyway"
    fi
  fi
  if [[ -w "$USBDEV" ]]; then
    EDL() { "$PYBIN" "$EDL_DIR/edl/edl.py" --loader="$LOADER" "$@"; }
  else
    EDL() { sudo -E "$PYBIN" "$EDL_DIR/edl/edl.py" --loader="$LOADER" "$@"; }
  fi
  # Cerro ABL marks a slot unbootable and switches; always keep A==B.
  EDL w boot_a "$BOOT"
  EDL w boot_b "$BOOT"
  EDL w vendor_boot_a "$STOCK_VB"
  EDL w vendor_boot_b "$STOCK_VB"
  EDL e dtbo_a || true
  EDL e dtbo_b || true
  echo "EDL dual-slot flash done: boot_{a,b}+vendor_boot_{a,b}, dtbo erased"
  EDL reset || true
}

flash_fastboot() {
  echo "==== via fastboot (both A/B slots) ===="
  local ok_a=0 ok_b=0
  # Never short-circuit: a half-flash leaves A≠B → ABL slot-switch / reboot loop.
  if fb flash boot_a "$BOOT"; then ok_a=1; else echo "WARN: boot_a flash failed"; fi
  if fb flash boot_b "$BOOT"; then ok_b=1; else echo "WARN: boot_b flash failed"; fi
  if [[ "$ok_a" -eq 0 && "$ok_b" -eq 0 ]]; then
    if fb flash boot "$BOOT"; then
      echo "WARN: only flashed current 'boot' (single slot) — prefer EDL 9008 for dual-slot"
    else
      echo "WARN: fastboot flash failed"
      return 1
    fi
  elif [[ "$ok_a" -eq 0 || "$ok_b" -eq 0 ]]; then
    echo "WARN: only one boot slot updated (a=$ok_a b=$ok_b) — re-enter 9008 for full dual-slot"
    return 1
  fi
  # Keep vendor_boot identical too when stock image is available.
  if [[ -f "$STOCK_VB" ]]; then
    fb flash vendor_boot_a "$STOCK_VB" 2>/dev/null || echo "WARN: vendor_boot_a flash skipped/failed"
    fb flash vendor_boot_b "$STOCK_VB" 2>/dev/null || echo "WARN: vendor_boot_b flash skipped/failed"
  fi
  fb erase dtbo_a 2>/dev/null || fb erase dtbo 2>/dev/null || true
  fb erase dtbo_b 2>/dev/null || true
  fb set_active a 2>/dev/null || true
  echo "fastboot dual-slot flash done: boot_a+boot_b"
  fb continue 2>/dev/null || fb reboot 2>/dev/null || true
  return 0
}

# Prefer true EDL whenever present (even if sticky fastboot also listed).
if lsusb | grep -q '05c6:9008'; then
  flash_edl
  exit 0
fi

if lsusb | grep -q '18d1:d00d' && fb devices 2>/dev/null | grep -q fastboot; then
  if flash_fastboot; then
    exit 0
  fi
  echo "WARN: fastboot path failed — try oem edl / wait for 9008"
  fb oem edl 2>/dev/null || fb reboot-edl 2>/dev/null || true
fi

echo "waiting for 9008 (or healthy fastboot)..."
for i in $(seq 1 120); do
  # Always prefer 9008 first in the poll loop.
  if lsusb | grep -q '05c6:9008'; then
    flash_edl
    exit 0
  fi
  if lsusb | grep -q '18d1:d00d' && fb devices 2>/dev/null | grep -q fastboot; then
    if flash_fastboot; then
      exit 0
    fi
  fi
  if lsusb | grep -q '19d2:0112'; then
    echo "[$i] MemoryDump — 强制关机后音量±进 9008"
  fi
  sleep 2
done
echo "TIMEOUT: no fastboot/9008"
exit 1
