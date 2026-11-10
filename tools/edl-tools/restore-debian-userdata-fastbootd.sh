#!/usr/bin/env bash
# Restore the verified full-capacity native-Debian userdata sparse image only.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
BACKUP="$ROOT/backups/debian-native-20260817"
IMAGE="$BACKUP/userdata-debian-native-v2.sparse.img"
LOG="$BACKUP/userdata-v2-fastbootd-restore.log"
FB="${FB:-fastboot}"
EXPECTED_IMAGE=48fb7f92da0bb0203ef8ddbc224490ac502ae67edf5b6c3630552ec97f874000
EXPECTED_BACKUP_MANIFEST=248b1ea3fc1ee070ef96e6a69e67a16c8b36528639a06ea750531adf80eb7c4a
EXPECTED_PARTITION_BYTES=494387671040

[[ -n "$($FB devices 2>/dev/null)" ]] || {
  echo 'FAIL: no fastboot transport' >&2
  exit 1
}
userspace="$($FB getvar is-userspace 2>&1)"
grep -qE 'is-userspace:[[:space:]]*yes' <<<"$userspace" || {
  echo 'FAIL: transport is not fastbootd userspace' >&2
  exit 1
}
slot="$($FB getvar current-slot 2>&1)"
grep -qE 'current-slot:[[:space:]]*a' <<<"$slot" || {
  echo 'FAIL: current slot is not verified original slot a' >&2
  exit 1
}
[[ "$(sha256sum "$IMAGE" | awk '{print $1}')" == "$EXPECTED_IMAGE" ]] || {
  echo 'FAIL: Debian userdata sparse hash changed' >&2
  exit 1
}
[[ "$(sha256sum "$BACKUP/pre-aosp-partitions/IMAGES.SHA256SUMS" | awk '{print $1}')" == "$EXPECTED_BACKUP_MANIFEST" ]] || {
  echo 'FAIL: pre-AOSP partition manifest changed' >&2
  exit 1
}
(cd "$BACKUP/pre-aosp-partitions" && sha256sum -c IMAGES.SHA256SUMS)

size_line="$($FB getvar partition-size:userdata 2>&1)"
size_hex="$(sed -nE 's/.*partition-size:userdata:[[:space:]]*0x([0-9A-Fa-f]+).*/\1/p' <<<"$size_line" | head -1)"
[[ -n "$size_hex" ]] || {
  echo 'FAIL: fastboot did not report userdata partition size' >&2
  exit 1
}
size_dec="$((16#$size_hex))"
[[ "$size_dec" == "$EXPECTED_PARTITION_BYTES" ]] || {
  echo "FAIL: userdata size=$size_dec expected=$EXPECTED_PARTITION_BYTES" >&2
  exit 1
}

echo "FLASH userdata sparse_file_bytes=$(stat -c %s "$IMAGE") logical_bytes=$EXPECTED_PARTITION_BYTES"
"$FB" flash userdata "$IMAGE" >"$LOG" 2>&1
grep -q 'Finished. Total time:' "$LOG" || {
  echo 'FAIL: fastboot userdata log lacks completion marker' >&2
  exit 1
}
sync
echo 'PASS: verified full-capacity Debian userdata V2 sparse written; remaining in fastbootd'
