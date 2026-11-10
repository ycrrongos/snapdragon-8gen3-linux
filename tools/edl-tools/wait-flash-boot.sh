#!/usr/bin/env bash
# Wait for either EDL 9008 *or* sticky/normal fastboot (18d1:d00d), then flash boot.
# Prefer this over ad-hoc "wait 9008 only" loops.
set -euo pipefail
IMG=${1:?usage: wait-flash-boot.sh <boot.img>}
test -f "$IMG"
FLASH=/mnt/data/LOA_Nubia_Z60U/tools/edl-tools/flash-boot-any.sh

echo "Waiting for 05c6:9008 (EDL) or 18d1:d00d (fastboot)..."
for i in $(seq 1 300); do
  if lsusb 2>/dev/null | grep -q '05c6:9008'; then
    echo "[$i] EDL 9008"
    exec "$FLASH" "$IMG"
  fi
  if lsusb 2>/dev/null | grep -q '18d1:d00d'; then
    if fastboot devices 2>/dev/null | grep -q fastboot; then
      echo "[$i] fastboot"
      exec "$FLASH" "$IMG"
    fi
    echo "[$i] 18d1:d00d seen but fastboot devices empty — retry"
  fi
  sleep 2
done
echo "TIMEOUT: neither 9008 nor usable fastboot"
exit 1
