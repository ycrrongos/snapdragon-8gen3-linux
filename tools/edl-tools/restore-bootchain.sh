#!/usr/bin/env bash
# Restore boot-critical partitions via Qualcomm 9008 (EDL).
# Device: Nubia Z60 Ultra (NX721J / caza|cerro) — sm8650_v1 firehose ONLY.
#
# Prerequisites:
#   1. Phone in true EDL 9008 (lsusb shows 05c6:9008), NOT memorydump 19d2:0112
#   2. udev rules installed (./install-udev.sh)
#
# Enter 9008 (power off first):
#   Hold Vol+ AND Vol-, plug USB; or adb reboot edl when adb works.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL/venv/bin/activate"

LOADER="${EDL_LOADER:-$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf}"
BUILT="${EDL_BUILT:-/tmp/caza-imgs}"
BACKUP="${EDL_BACKUP:-/mnt/data/ArtistAOSP/backups/device-dump-20260717-222750/by-name}"
MODE="${1:-built}"   # built | backup | stock-abl

EDL=(python3 "$TOOL/edl/edl.py" --loader="$LOADER")

need_9008() {
  if ! lsusb | grep -qiE '05c6:9008|Qualcomm.*9008'; then
    echo "ERROR: 未检测到 05c6:9008。"
    echo "当前 USB:"
    lsusb | grep -iE '19d2|05c6|18d1' || lsusb | tail -5
    echo
    echo "若是 19d2:0112 (memorydump)：长按电源强制关机，再 Vol+ + Vol- 插 USB 进 9008。"
    exit 1
  fi
}

pick_img() {
  local name="$1"   # e.g. vendor_boot  or vendor_boot_a
  local slot_suffix="${2:-}"
  if [[ "$MODE" == "backup" ]]; then
    local f="$BACKUP/${name}${slot_suffix}.img"
    [[ -f "$f" ]] || f="$BACKUP/${name}.img"
    [[ -f "$f" ]] || { echo "missing $f"; return 1; }
    echo "$f"
    return
  fi
  # built: prefer /tmp/caza-imgs/<name>.img (no slot suffix in zip)
  local base="${name%_a}"
  base="${base%_b}"
  local f="$BUILT/${base}.img"
  if [[ -f "$f" ]]; then
    echo "$f"
    return
  fi
  # fallback backup
  f="$BACKUP/${name}${slot_suffix}.img"
  [[ -f "$f" ]] || f="$BACKUP/${base}_a.img"
  [[ -f "$f" ]] || { echo "missing image for $name"; return 1; }
  echo "$f"
}

flash_one() {
  local part="$1" img="$2"
  echo "==== flash $part <= $(basename "$img") ($(du -h "$img" | awk '{print $1}')) ===="
  "${EDL[@]}" w "$part" "$img"
}

need_9008
echo "MODE=$MODE LOADER=$(basename "$LOADER")"
echo "==== printgpt (smoke test) ===="
"${EDL[@]}" printgpt | head -80

case "$MODE" in
  stock-abl)
    echo "==== flash eng abl (unlock helper, sm8650_v1) ===="
    flash_one abl_a "$TOOL/nubia_sm8650_eng/eng_v1/abl.img"
    flash_one abl_b "$TOOL/nubia_sm8650_eng/eng_v1/abl.img"
    ;;
  built|backup)
    # Fix the panic-inducing debug vendor_boot first, then rest of boot chain
    for slot in a b; do
      flash_one "vendor_boot_${slot}" "$(pick_img vendor_boot "_${slot}")"
      flash_one "boot_${slot}" "$(pick_img boot "_${slot}")"
      flash_one "init_boot_${slot}" "$(pick_img init_boot "_${slot}")"
      flash_one "dtbo_${slot}" "$(pick_img dtbo "_${slot}")"
      flash_one "recovery_${slot}" "$(pick_img recovery "_${slot}")"
      flash_one "vbmeta_${slot}" "$(pick_img vbmeta "_${slot}")"
      flash_one "vbmeta_system_${slot}" "$(pick_img vbmeta_system "_${slot}")"
      # pvmfw if present
      if [[ -f "$BUILT/pvmfw.img" ]] || [[ -f "$BACKUP/pvmfw_${slot}.img" ]]; then
        flash_one "pvmfw_${slot}" "$(pick_img pvmfw "_${slot}")" || true
      fi
    done
    ;;
  *)
    echo "Usage: $0 [built|backup|stock-abl]"
    exit 2
    ;;
esac

echo "==== reset ===="
"${EDL[@]}" reset || true
echo "Done. 若仍进不了 recovery/fastboot，再跑: $0 backup"
