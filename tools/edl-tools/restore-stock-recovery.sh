#!/usr/bin/env bash
# Emergency: restore ORIGINAL recovery (+ vbmeta) via 9008.
# Do NOT use the patched 18MB failsafe recovery.
set -euo pipefail
TOOL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL/venv/bin/activate"
LOADER="${EDL_LOADER:-$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf}"
REC="${STOCK_RECOVERY:-/tmp/caza-imgs/recovery.img}"
VBMETA="${STOCK_VBMETA:-/tmp/caza-imgs/vbmeta.img}"
VBMETA_SYS_FLAGS3="${VBMETA_SYS_FLAGS3:-/tmp/caza-failsafe/vbmeta_system_flags3.img}"
EDL=(python3 "$TOOL/edl/edl.py" --loader="$LOADER" --memory=ufs)

if ! lsusb | grep -qi '05c6:9008'; then
  echo "需要 05c6:9008"
  lsusb | grep -iE '19d2|05c6|18d1' || true
  exit 1
fi

[[ -f "$REC" ]] || REC=/mnt/data/ArtistAOSP/source/out/target/product/caza/recovery.img
[[ -f "$VBMETA" ]] || VBMETA=/mnt/data/ArtistAOSP/source/out/target/product/caza/vbmeta.img

echo "Using recovery: $REC ($(du -h "$REC" | awk '{print $1}'))"
echo "==== flash stock recovery a/b ===="
"${EDL[@]}" w recovery_a "$REC"
"${EDL[@]}" w recovery_b "$REC"

if [[ -f "$VBMETA" ]]; then
  echo "==== flash vbmeta a/b (flags already 3 in file if patched) ===="
  "${EDL[@]}" w vbmeta_a "$VBMETA"
  "${EDL[@]}" w vbmeta_b "$VBMETA"
fi

# Keep vbmeta_system disabled so previously flashed logicals still mount
if [[ -f "$VBMETA_SYS_FLAGS3" ]]; then
  echo "==== flash vbmeta_system flags3 ===="
  "${EDL[@]}" w vbmeta_system_a "$VBMETA_SYS_FLAGS3"
  "${EDL[@]}" w vbmeta_system_b "$VBMETA_SYS_FLAGS3"
fi

echo "==== reset ===="
"${EDL[@]}" reset || true
echo "Done — stock recovery restored. Try: Vol+ + Power -> recovery"
