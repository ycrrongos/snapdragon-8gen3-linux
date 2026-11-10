#!/usr/bin/env bash
# Restore and read back every exact pre-AOSP partition image, then slot a.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
BACKUP="$ROOT/backups/debian-native-20260817"
PARTS_DIR="$BACKUP/pre-aosp-partitions"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"
EXPECTED_BACKUP_MANIFEST=248b1ea3fc1ee070ef96e6a69e67a16c8b36528639a06ea750531adf80eb7c4a
EXPECTED_USERDATA=48fb7f92da0bb0203ef8ddbc224490ac502ae67edf5b6c3630552ec97f874000

PARTS=(
  metadata misc pvmfw_a pvmfw_b recovery_a recovery_b
  vbmeta_system_a vbmeta_system_b vbmeta_a vbmeta_b dtbo_a dtbo_b
  vendor_boot_a vendor_boot_b init_boot_a init_boot_b boot_a boot_b
)

EDL() {
  sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" "$@"
}

lsusb -d 05c6:9008 | grep -q '05c6:9008' || {
  echo 'FAIL: exact 05c6:9008 device is not present' >&2
  exit 1
}
[[ "$(sha256sum "$PARTS_DIR/IMAGES.SHA256SUMS" | awk '{print $1}')" == "$EXPECTED_BACKUP_MANIFEST" ]] || {
  echo 'FAIL: pre-AOSP backup manifest changed' >&2
  exit 1
}
(cd "$PARTS_DIR" && sha256sum -c IMAGES.SHA256SUMS)
[[ "$(sha256sum "$BACKUP/userdata-debian-native-v2.sparse.img" | awk '{print $1}')" == "$EXPECTED_USERDATA" ]] || {
  echo 'FAIL: restored userdata sparse artifact hash changed' >&2
  exit 1
}
grep -q 'Finished. Total time:' "$BACKUP/userdata-v2-fastbootd-restore.log" || {
  echo 'FAIL: userdata fastbootd restore completion marker is missing' >&2
  exit 1
}
grep -q 'Current active slot: a' "$PARTS_DIR/original-slot.edl.log" || {
  echo 'FAIL: original active slot is not verified as a' >&2
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
  image="$PARTS_DIR/$part.img"
  expected="$(stat -c %s "$image")"
  echo "RESTORE $part bytes=$expected"
  EDL w "$part" "$image" >"$PARTS_DIR/$part.restore-write.log" 2>&1
  verify_image="$PARTS_DIR/$part.restore-readback.img"
  EDL r "$part" "$verify_image" >"$PARTS_DIR/$part.restore-readback.log" 2>&1
  [[ "$(stat -c %s "$verify_image")" == "$expected" ]] || {
    echo "FAIL: $part restored readback size differs" >&2
    exit 1
  }
  cmp -s "$image" "$verify_image" || {
    echo "FAIL: $part restored readback differs byte-for-byte" >&2
    exit 1
  }
  rm -- "$verify_image"
  verify_image=
  echo "PASS $part exact readback"
done

echo 'SET ACTIVE SLOT a'
EDL setactiveslot a >"$PARTS_DIR/restore-set-slot-a.log" 2>&1
EDL getactiveslot >"$PARTS_DIR/restored-slot.edl.log" 2>&1
grep -q 'Current active slot: a' "$PARTS_DIR/restored-slot.edl.log" || {
  echo 'FAIL: active-slot readback is not a' >&2
  exit 1
}
echo 'PASS active slot a readback'
sync
echo 'RESET into restored Debian'
EDL reset >"$PARTS_DIR/debian-edl-reset.log" 2>&1 || true
echo 'PASS: all 18 exact partitions and slot a restored/read back; reset issued'
