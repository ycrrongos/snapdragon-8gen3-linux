#!/usr/bin/env bash
# Flash logo-watchdog + recovery-adb patches via 9008.
# Requires: 05c6:9008, sm8650_v1 loader
set -euo pipefail
TOOL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL/venv/bin/activate"
LOADER="${EDL_LOADER:-$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf}"
IMG="${FAILSAFE_IMG:-/tmp/caza-failsafe}"
EDL=(python3 "$TOOL/edl/edl.py" --loader="$LOADER")

if ! lsusb | grep -qi '05c6:9008'; then
  echo "需要 05c6:9008。当前:"
  lsusb | grep -iE '19d2|05c6' || true
  exit 1
fi

echo "==== printgpt ===="
"${EDL[@]}" printgpt

flash() {
  local part="$1" file="$2"
  echo "==== w $part <= $(basename "$file") ===="
  "${EDL[@]}" w "$part" "$file"
}

# Disable AVB for modified system
flash vbmeta_system_a "$IMG/vbmeta_system_flags3.img"
flash vbmeta_system_b "$IMG/vbmeta_system_flags3.img"
# Keep top vbmeta disabled too
flash vbmeta_a "$IMG/vbmeta.img"
flash vbmeta_b "$IMG/vbmeta.img"

flash system_a "$IMG/system_failsafe.img"
flash system_b "$IMG/system_failsafe.img"
flash recovery_a "$IMG/recovery_failsafe.img"
flash recovery_b "$IMG/recovery_failsafe.img"

echo "==== reset ===="
"${EDL[@]}" reset || true
echo "Done. 若卡 logo>15s 应自动进 recovery，且 adb 默认开启。"
