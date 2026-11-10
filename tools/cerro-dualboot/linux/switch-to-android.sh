#!/bin/bash
# Run as root on Debian (slot B): switch to Android on slot A and reboot.
# Architecture: A=Android, B=Linux — slot switch only, no partition writes.
# (dd-based full restore lives in switch-repair-android.sh; only needed if A is broken.)
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo "need root (sudo)" >&2; exit 1; }
Q=/usr/bin/qbootctl
[[ -x $Q ]] || { echo "missing $Q" >&2; exit 1; }

echo "=== cerro dualboot: Linux(slot B) -> Android(slot A) ==="
echo "-- current slot info:"
"$Q" -a 2>&1 | sed 's/^/   /' || true
"$Q" -c 2>&1 | sed 's/^/   /' || true

# B is healthy/successful (marked at first boot); A already holds the Android chain.
echo "-- set active slot A"
"$Q" -s 0
sync
echo "OK: rebooting into Android (slot A)"
reboot
