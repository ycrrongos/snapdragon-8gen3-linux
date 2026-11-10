#!/usr/bin/env bash
# Restore partitions backed up before pmOS flash.
set -euo pipefail
TOOL="$(cd "$(dirname "$0")" && pwd)"
BACKUP="${1:-$TOOL/pmos-flash/backup-20260806-020517}"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"
EDL() { sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" "$@"; }
lsusb | grep -qi 05c6:9008 || { echo "need 9008"; exit 1; }
for p in boot_a boot_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b; do
  echo "==== restore $p ===="
  EDL w "$p" "$BACKUP/${p}.img"
done
EDL reset || true
echo Done.
