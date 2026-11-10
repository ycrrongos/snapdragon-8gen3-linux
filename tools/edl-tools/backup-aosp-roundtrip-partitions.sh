#!/usr/bin/env bash
# Read every partition that the authorized AOSP round trip must restore.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
OUT="${1:-$ROOT/backups/debian-native-20260817/pre-aosp-partitions}"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"

PARTS=(
  boot_a boot_b init_boot_a init_boot_b vendor_boot_a vendor_boot_b
  dtbo_a dtbo_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b
  recovery_a recovery_b pvmfw_a pvmfw_b misc metadata
)
declare -A EXPECTED_SIZE=(
  [boot_a]=100663296 [boot_b]=100663296
  [init_boot_a]=8388608 [init_boot_b]=8388608
  [vendor_boot_a]=100663296 [vendor_boot_b]=100663296
  [dtbo_a]=25165824 [dtbo_b]=25165824
  [vbmeta_a]=65536 [vbmeta_b]=65536
  [vbmeta_system_a]=65536 [vbmeta_system_b]=65536
  [recovery_a]=104857600 [recovery_b]=104857600
  [pvmfw_a]=1048576 [pvmfw_b]=1048576
  [misc]=1048576 [metadata]=67108864
)

lsusb -d 05c6:9008 | grep -q '05c6:9008' || {
  echo 'FAIL: exact 05c6:9008 device is not present' >&2
  exit 1
}
[[ -f "$LOADER" && -x "$PY" ]] || {
  echo 'FAIL: exact loader or EDL Python is missing' >&2
  exit 1
}
mkdir -p "$OUT"

for part in "${PARTS[@]}"; do
  image="$OUT/$part.img"
  verify="$OUT/$part.verify.img"
  log1="$OUT/$part.read1.log"
  log2="$OUT/$part.read2.log"
  if [[ -e "$image" || -e "$verify" || -e "$log1" || -e "$log2" ]]; then
    echo "FAIL: refusing to overwrite existing backup material for $part" >&2
    exit 1
  fi

  echo "READ1 $part expected=${EXPECTED_SIZE[$part]}"
  sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" \
    r "$part" "$image" >"$log1" 2>&1
  actual="$(stat -c %s "$image")"
  [[ "$actual" == "${EXPECTED_SIZE[$part]}" ]] || {
    echo "FAIL: $part first read size=$actual expected=${EXPECTED_SIZE[$part]}" >&2
    exit 1
  }

  echo "READ2 $part expected=${EXPECTED_SIZE[$part]}"
  sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" \
    r "$part" "$verify" >"$log2" 2>&1
  actual2="$(stat -c %s "$verify")"
  [[ "$actual2" == "${EXPECTED_SIZE[$part]}" ]] || {
    echo "FAIL: $part second read size=$actual2 expected=${EXPECTED_SIZE[$part]}" >&2
    exit 1
  }
  cmp -s "$image" "$verify" || {
    echo "FAIL: $part two EDL reads differ" >&2
    exit 1
  }
  rm -- "$verify"
  digest="$(sha256sum "$image" | awk '{print $1}')"
  echo "PASS $part size=$actual sha256=${digest:0:12}..."
done

manifest_tmp="$OUT/IMAGES.SHA256SUMS.part"
manifest="$OUT/IMAGES.SHA256SUMS"
: >"$manifest_tmp"
for part in "${PARTS[@]}"; do
  (cd "$OUT" && sha256sum "$part.img") >>"$manifest_tmp"
done
mv "$manifest_tmp" "$manifest"
(cd "$OUT" && sha256sum -c IMAGES.SHA256SUMS)
sync
echo "PASS: ${#PARTS[@]} exact partition images read twice, compared, sized and hashed"
