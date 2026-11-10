#!/usr/bin/env bash
# Source this:  source /mnt/data/ArtistAOSP/edl-tools/edl-env.sh
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL/venv/bin/activate"
export EDL_TOOLS="$TOOL"
export EDL_BIN="$TOOL/edl/edl.py"
# Z60 Ultra / NX721J / caza|cerro -> sm8650_v1
export EDL_LOADER="${EDL_LOADER:-$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf}"
export EDL_BACKUP="${EDL_BACKUP:-/mnt/data/ArtistAOSP/backups/device-dump-20260717-222750/by-name}"
export EDL_BUILT="${EDL_BUILT:-/tmp/caza-imgs}"

edl() {
  python3 "$EDL_BIN" "$@" --loader="$EDL_LOADER"
}

edl-printgpt() {
  edl printgpt
}

edl-reset() {
  edl reset
}

echo "EDL ready. loader=$(basename "$EDL_LOADER")"
echo "  edl printgpt"
echo "  edl w vendor_boot_a \$EDL_BUILT/vendor_boot.img"
echo "  ./restore-bootchain.sh"
