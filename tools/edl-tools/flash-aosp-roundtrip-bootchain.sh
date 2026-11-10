#!/usr/bin/env bash
# Hash-locked EDL stage for the explicitly authorized AOSP cellular round trip.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
AOSP="/mnt/data/aosp/out/target/product/cerro"
BACKUP="$ROOT/backups/debian-native-20260817/pre-aosp-partitions"
MANIFEST="$ROOT/notes/bisect-logs/aosp-cellular-roundtrip-20260817.sha256"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"
MISC_IMAGE="$ROOT/中兴家族工具箱1.2.8-beta4/bin/tool/Android/misc_torecovery.img"
EXPECTED_MANIFEST=46535ef76dc4312622c75201f897f137fd095f9614f597e46febe30890b89483
EXPECTED_BACKUP_MANIFEST=248b1ea3fc1ee070ef96e6a69e67a16c8b36528639a06ea750531adf80eb7c4a
EXPECTED_MISC=837cb829cafa2a6f620266319708ef8820e74717981ee63250afb007c521eed3

PARTS=(
  boot_a boot_b init_boot_a init_boot_b vendor_boot_a vendor_boot_b
  dtbo_a dtbo_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b
  recovery_a recovery_b pvmfw_a
)
declare -A SOURCE=(
  [boot_a]="$AOSP/boot.img" [boot_b]="$AOSP/boot.img"
  [init_boot_a]="$AOSP/init_boot.img" [init_boot_b]="$AOSP/init_boot.img"
  [vendor_boot_a]="$AOSP/vendor_boot.img" [vendor_boot_b]="$AOSP/vendor_boot.img"
  [dtbo_a]="$AOSP/dtbo.img" [dtbo_b]="$AOSP/dtbo.img"
  [vbmeta_a]="$AOSP/vbmeta.img" [vbmeta_b]="$AOSP/vbmeta.img"
  [vbmeta_system_a]="$AOSP/vbmeta_system.img" [vbmeta_system_b]="$AOSP/vbmeta_system.img"
  [recovery_a]="$AOSP/recovery.img" [recovery_b]="$AOSP/recovery.img"
  [pvmfw_a]="$AOSP/pvmfw.img"
)
declare -A PART_SIZE=(
  [boot_a]=100663296 [boot_b]=100663296
  [init_boot_a]=8388608 [init_boot_b]=8388608
  [vendor_boot_a]=100663296 [vendor_boot_b]=100663296
  [dtbo_a]=25165824 [dtbo_b]=25165824
  [vbmeta_a]=65536 [vbmeta_b]=65536
  [vbmeta_system_a]=65536 [vbmeta_system_b]=65536
  [recovery_a]=104857600 [recovery_b]=104857600
  [pvmfw_a]=1048576 [misc]=1048576
)

EDL() {
  sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" "$@"
}

lsusb -d 05c6:9008 | grep -q '05c6:9008' || {
  echo 'FAIL: exact 05c6:9008 device is not present' >&2
  exit 1
}
[[ "$(sha256sum "$MANIFEST" | awk '{print $1}')" == "$EXPECTED_MANIFEST" ]] || {
  echo 'FAIL: AOSP manifest hash changed' >&2
  exit 1
}
sha256sum -c "$MANIFEST"
[[ "$(sha256sum "$BACKUP/IMAGES.SHA256SUMS" | awk '{print $1}')" == "$EXPECTED_BACKUP_MANIFEST" ]] || {
  echo 'FAIL: pre-AOSP backup manifest changed' >&2
  exit 1
}
(cd "$BACKUP" && sha256sum -c IMAGES.SHA256SUMS)
grep -q 'Current active slot: a' "$BACKUP/original-slot.edl.log" || {
  echo 'FAIL: original active slot is not verified as a' >&2
  exit 1
}
[[ "$(stat -c %s "$MISC_IMAGE")" == 8192 ]] || {
  echo 'FAIL: recovery BCB image is not 8192 bytes' >&2
  exit 1
}
[[ "$(sha256sum "$MISC_IMAGE" | awk '{print $1}')" == "$EXPECTED_MISC" ]] || {
  echo 'FAIL: recovery BCB image hash changed' >&2
  exit 1
}
[[ "$(LC_ALL=C tr -d '\000' <"$MISC_IMAGE")" == boot-recovery ]] || {
  echo 'FAIL: recovery BCB image contains unexpected nonzero data' >&2
  exit 1
}

verify_image=
cleanup() {
  if [[ -n "$verify_image" && -e "$verify_image" ]]; then
    rm -- "$verify_image"
  fi
}
trap cleanup EXIT

for part in "${PARTS[@]}"; do
  image="${SOURCE[$part]}"
  image_size="$(stat -c %s "$image")"
  (( image_size <= PART_SIZE[$part] )) || {
    echo "FAIL: $part source is larger than its GPT partition" >&2
    exit 1
  }
  echo "WRITE $part bytes=$image_size"
  EDL w "$part" "$image" >"$BACKUP/$part.aosp-write.log" 2>&1
  verify_image="$BACKUP/$part.aosp-readback.img"
  EDL r "$part" "$verify_image" >"$BACKUP/$part.aosp-readback.log" 2>&1
  [[ "$(stat -c %s "$verify_image")" == "${PART_SIZE[$part]}" ]] || {
    echo "FAIL: $part readback has wrong partition size" >&2
    exit 1
  }
  cmp -n "$image_size" "$image" "$verify_image" || {
    echo "FAIL: $part readback prefix differs" >&2
    exit 1
  }
  rm -- "$verify_image"
  verify_image=
  echo "PASS $part readback"
done

echo 'WRITE misc boot-recovery bytes=8192'
EDL w misc "$MISC_IMAGE" >"$BACKUP/misc.aosp-write.log" 2>&1
verify_image="$BACKUP/misc.aosp-readback.img"
EDL r misc "$verify_image" >"$BACKUP/misc.aosp-readback.log" 2>&1
[[ "$(stat -c %s "$verify_image")" == "${PART_SIZE[misc]}" ]] || {
  echo 'FAIL: misc readback has wrong partition size' >&2
  exit 1
}
cmp -n 8192 "$MISC_IMAGE" "$verify_image" || {
  echo 'FAIL: misc BCB prefix differs' >&2
  exit 1
}
cmp -i 8192:8192 "$BACKUP/misc.img" "$verify_image" || {
  echo 'FAIL: misc bytes after BCB prefix unexpectedly changed' >&2
  exit 1
}
rm -- "$verify_image"
verify_image=
echo 'PASS misc boot-recovery readback'

sync
echo 'RESET into AOSP recovery'
EDL reset >"$BACKUP/aosp-edl-reset.log" 2>&1 || true
echo 'PASS: authorized AOSP boot chain written and read back; reset issued'
