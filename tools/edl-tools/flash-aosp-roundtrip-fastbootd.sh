#!/usr/bin/env bash
# Hash-locked fastbootd stage for the authorized AOSP cellular round trip.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
AOSP="/mnt/data/aosp/out/target/product/cerro"
BACKUP="$ROOT/backups/debian-native-20260817"
MANIFEST="$ROOT/notes/bisect-logs/aosp-cellular-roundtrip-20260817.sha256"
FB="${FB:-fastboot}"
EXPECTED_MANIFEST=46535ef76dc4312622c75201f897f137fd095f9614f597e46febe30890b89483
EXPECTED_BACKUP_MANIFEST=248b1ea3fc1ee070ef96e6a69e67a16c8b36528639a06ea750531adf80eb7c4a
EXPECTED_USERDATA=48fb7f92da0bb0203ef8ddbc224490ac502ae67edf5b6c3630552ec97f874000

LOGDIR="$BACKUP/aosp-fastbootd-logs"
PARTS=(odm product system system_dlkm system_ext vendor vendor_dlkm)

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
  echo 'FAIL: current slot is not the verified original slot a' >&2
  exit 1
}
[[ "$(sha256sum "$MANIFEST" | awk '{print $1}')" == "$EXPECTED_MANIFEST" ]] || {
  echo 'FAIL: AOSP manifest hash changed' >&2
  exit 1
}
sha256sum -c "$MANIFEST"
[[ "$(sha256sum "$BACKUP/pre-aosp-partitions/IMAGES.SHA256SUMS" | awk '{print $1}')" == "$EXPECTED_BACKUP_MANIFEST" ]] || {
  echo 'FAIL: pre-AOSP partition manifest changed' >&2
  exit 1
}
(cd "$BACKUP/pre-aosp-partitions" && sha256sum -c IMAGES.SHA256SUMS)
[[ "$(sha256sum "$BACKUP/userdata-debian-native-v2.sparse.img" | awk '{print $1}')" == "$EXPECTED_USERDATA" ]] || {
  echo 'FAIL: verified Debian userdata sparse image changed' >&2
  exit 1
}

mkdir -p "$LOGDIR"
for part in "${PARTS[@]}"; do
  image="$AOSP/$part.img"
  echo "FLASH $part bytes=$(stat -c %s "$image")"
  "$FB" flash "$part" "$image" >"$LOGDIR/$part.flash.log" 2>&1
  grep -q 'Finished. Total time:' "$LOGDIR/$part.flash.log" || {
    echo "FAIL: $part fastboot log lacks completion marker" >&2
    exit 1
  }
  echo "PASS $part"
done

echo 'ERASE userdata'
"$FB" erase userdata >"$LOGDIR/userdata.erase.log" 2>&1
grep -q 'Finished. Total time:' "$LOGDIR/userdata.erase.log" || {
  echo 'FAIL: userdata erase log lacks completion marker' >&2
  exit 1
}
echo 'PASS userdata erase'

echo 'ERASE metadata'
"$FB" erase metadata >"$LOGDIR/metadata.erase.log" 2>&1
grep -q 'Finished. Total time:' "$LOGDIR/metadata.erase.log" || {
  echo 'FAIL: metadata erase log lacks completion marker' >&2
  exit 1
}
echo 'PASS metadata erase'

sync
echo 'PASS: seven authorized dynamic partitions flashed; userdata and metadata erased'
