#!/usr/bin/env bash
# Restore Linux boot + pmOS_boot(logdump) + pmOS_root(userdata) from
# backups/linux-kde-YYYYMMDD after an Android (InfinityX) excursion.
#
# Usage (device must be in 9008):
#   tools/edl-tools/restore-linux-kde.sh [backup-dir]
#
# Default backup: backups/linux-kde-20260815
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$(cd "$(dirname "$0")" && pwd)"
BK="${1:-$ROOT/backups/linux-kde-20260815}"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"
BOOT_IMG="${BOOT_IMG:-$BK/boot-v2-disp-dpu-s5dk.img}"
# fallback if s5dk not present yet
[[ -f "$BOOT_IMG" ]] || BOOT_IMG="$BK/boot-v2-disp-dpu-s5dj.img"
LOGDUMP_IMG="$BK/logdump.img"
ROOT_TAR="$BK/pmos-root.tar.gz"
ROOT_UUID="${ROOT_UUID:-ab3a863b-512a-447e-a35c-e681ce0ae61b}"
BOOT_UUID="${BOOT_UUID:-0ad60230-638c-49c0-9c95-ab8938f81eaf}"

EDL() { sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" "$@"; }

need() { [[ -f "$1" ]] || { echo "missing: $1"; exit 1; }; }
need "$BOOT_IMG"
need "$LOGDUMP_IMG"
need "$ROOT_TAR"
# refuse truncated gzip
gzip -t "$ROOT_TAR" || { echo "ERROR: $ROOT_TAR fails gzip -t (incomplete backup)"; exit 1; }

lsusb | grep -qi 05c6:9008 || { echo "need 9008 (EDL)"; exit 1; }

echo "==== flash Linux boot (dual slot) ===="
for s in a b; do
  EDL w "boot_${s}" "$BOOT_IMG"
  EDL e "dtbo_${s}" || true
  EDL e "init_boot_${s}" || true
done

echo "==== restore pmOS_boot -> logdump ===="
EDL w logdump "$LOGDUMP_IMG"

echo "==== rewrite userdata with pmOS_root ===="
# Stage tar via host tmp raw image if present; else instruct manual.
# Prefer: write a fresh ext4 image large enough, untar, then EDL w userdata.
STAGE="${STAGE:-$BK/userdata-restored.img}"
if [[ ! -f "$STAGE" ]]; then
  echo "Building staged userdata image (this needs free disk ~ used+20%)..."
  SIZE_G="${USERDATA_STAGE_G:-12}"
  truncate -s "${SIZE_G}G" "$STAGE"
  mkfs.ext4 -F -L pmOS_root -U "$ROOT_UUID" "$STAGE"
  MNT=$(mktemp -d /tmp/pmos-restore-XXXX)
  sudo mount -o loop "$STAGE" "$MNT"
  sudo tar -C "$MNT" -xzf "$ROOT_TAR"
  sudo umount "$MNT"
  rmdir "$MNT"
fi
EDL w userdata "$STAGE"

echo "==== reset ===="
EDL reset || true
echo "DONE. After boot: ACM login user/user; KDE if packages were in the tar."
echo "If boot fails UUID mismatch, check $BK/blkid.txt"
