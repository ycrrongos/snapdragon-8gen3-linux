#!/usr/bin/env bash
# Flash postmarketOS boot.img (+ AVB-off vbmeta) to Nubia Z60 Ultra (cerro)
# via Qualcomm 9008 EDL. Does NOT touch xbl/abl.
#
# Prerequisites:
#   1. Phone in true EDL 9008 (lsusb → 05c6:9008), NOT 19d2:0112 memorydump
#   2. pmbootstrap install finished (or pass BOOT_IMG=... explicitly)
#   3. udev rules installed (./install-udev.sh)
#
# Usage:
#   ./flash-pmos-boot.sh              # flash boot_a + vbmeta (both slots)
#   ./flash-pmos-boot.sh a            # only slot a
#   BOOT_IMG=/path/to/boot.img ./flash-pmos-boot.sh
#   SKIP_VBMETA=1 ./flash-pmos-boot.sh   # boot only
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"

# Prefer project venv, fall back to ArtistAOSP copy
if [[ -f "$TOOL/venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$TOOL/venv/bin/activate"
elif [[ -f /mnt/data/ArtistAOSP/edl-tools/venv/bin/activate ]]; then
  # shellcheck disable=SC1091
  source /mnt/data/ArtistAOSP/edl-tools/venv/bin/activate
else
  echo "ERROR: edl venv not found. Create symlink:"
  echo "  ln -s /mnt/data/ArtistAOSP/edl-tools/venv $TOOL/venv"
  exit 1
fi

LOADER="${EDL_LOADER:-$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf}"
SLOT="${1:-both}"   # a | b | both
SKIP_VBMETA="${SKIP_VBMETA:-0}"

# Default: pmbootstrap's generated android boot.img
BOOT_IMG="${BOOT_IMG:-}"
if [[ -z "$BOOT_IMG" ]]; then
  for cand in \
    "$ROOT/pmbootstrap/work/chroot_rootfs_nubia-cerro/boot/boot.img" \
    "$ROOT/pmbootstrap/work/chroot_native/home/pmos/rootfs/nubia-cerro/boot.img" \
    "$TOOL/pmos-flash/boot.img"
  do
    if [[ -f "$cand" ]]; then
      BOOT_IMG="$cand"
      break
    fi
  done
fi

VBMETA_IMG="${VBMETA_IMG:-$TOOL/pmos-flash/vbmeta.img}"
VBMETA_SYSTEM_IMG="${VBMETA_SYSTEM_IMG:-$TOOL/pmos-flash/vbmeta_system.img}"

EDL=(python3 "$TOOL/edl/edl.py" --loader="$LOADER")

need_9008() {
  if ! lsusb | grep -qiE '05c6:9008|Qualcomm.*9008'; then
    echo "ERROR: 未检测到 05c6:9008。"
    echo "当前 USB:"
    lsusb | grep -iE '19d2|05c6|18d1' || lsusb | tail -5
    echo
    echo "进 9008: 长按电源强制关机 → 同时按住 Vol+ 和 Vol- → 插 USB"
    exit 1
  fi
}

flash_one() {
  local part="$1" img="$2"
  echo "==== flash $part <= $(basename "$img") ($(du -h "$img" | awk '{print $1}')) ===="
  "${EDL[@]}" w "$part" "$img"
}

need_9008

if [[ ! -f "$BOOT_IMG" ]]; then
  echo "ERROR: boot.img 不存在。"
  echo "先完成: pmbootstrap -c pmbootstrap/pmbootstrap_v3.cfg install"
  echo "或设置: BOOT_IMG=/path/to/boot.img"
  exit 1
fi
if [[ ! -f "$LOADER" ]]; then
  echo "ERROR: firehose loader missing: $LOADER"
  exit 1
fi

echo "LOADER=$(basename "$LOADER")"
echo "BOOT_IMG=$BOOT_IMG"
echo "SLOT=$SLOT SKIP_VBMETA=$SKIP_VBMETA"
echo "==== printgpt (smoke) ===="
"${EDL[@]}" printgpt | head -60

slots=()
case "$SLOT" in
  a|b) slots=("$SLOT") ;;
  both) slots=(a b) ;;
  *) echo "Usage: $0 [a|b|both]"; exit 2 ;;
esac

for s in "${slots[@]}"; do
  flash_one "boot_${s}" "$BOOT_IMG"
  if [[ "$SKIP_VBMETA" != "1" ]]; then
    [[ -f "$VBMETA_IMG" ]] || { echo "missing $VBMETA_IMG"; exit 1; }
    [[ -f "$VBMETA_SYSTEM_IMG" ]] || { echo "missing $VBMETA_SYSTEM_IMG"; exit 1; }
    flash_one "vbmeta_${s}" "$VBMETA_IMG"
    flash_one "vbmeta_system_${s}" "$VBMETA_SYSTEM_IMG"
  fi
done

echo "==== reset ===="
"${EDL[@]}" reset || true
echo "Done."
echo "注意: 首次 bring-up 若无 rootfs 镜像，内核可能起不来完整用户态；"
echo "      需要的话再用 pmbootstrap 产物刷 userdata/super 或走 netboot。"
