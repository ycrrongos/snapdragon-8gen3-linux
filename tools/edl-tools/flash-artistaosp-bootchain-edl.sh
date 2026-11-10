#!/usr/bin/env bash
# One-shot: EDL flash ArtistAOSP boot chain (dual-slot) + misc→recovery, then reset.
# Does NOT flash dynamic partitions (those need fastbootd next).
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
AOSP="${AOSP:-/mnt/data/ArtistAOSP/source/out/target/product/cerro}"
LOGDIR="${LOGDIR:-/tmp/cerro-artistaosp-edl-$(date +%Y%m%d-%H%M%S)}"
LOADER="$TOOL/nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf"
PY="$TOOL/venv/bin/python3"
MISC="$ROOT/中兴家族工具箱1.2.8-beta4/bin/tool/Android/misc_torecovery.img"

mkdir -p "$LOGDIR"
echo "LOGDIR=$LOGDIR"
echo "AOSP=$AOSP"

lsusb -d 05c6:9008 | grep -q '05c6:9008' || {
  echo 'FAIL: need 05c6:9008' >&2
  exit 1
}

EDL() {
  sudo -E "$PY" "$TOOL/edl/edl.py" --loader="$LOADER" "$@"
}

flash_one() {
  local part="$1" image="$2" max="$3"
  local sz
  sz="$(stat -c %s "$image")"
  (( sz <= max )) || { echo "FAIL: $part $sz > $max" >&2; exit 1; }
  echo "WRITE $part bytes=$sz from $image"
  EDL w "$part" "$image" | tee "$LOGDIR/$part.write.log"
}

# Dual-slot boot-critical + recovery/pvmfw (pvmfw_a only like prior roundtrip)
for s in a b; do
  flash_one "boot_${s}"        "$AOSP/boot.img"           100663296
  flash_one "init_boot_${s}"   "$AOSP/init_boot.img"       8388608
  flash_one "vendor_boot_${s}" "$AOSP/vendor_boot.img"    100663296
  flash_one "dtbo_${s}"        "$AOSP/dtbo.img"           25165824
  flash_one "vbmeta_${s}"      "$AOSP/vbmeta.img"            65536
  flash_one "vbmeta_system_${s}" "$AOSP/vbmeta_system.img"   65536
  flash_one "recovery_${s}"    "$AOSP/recovery.img"      104857600
done
flash_one "pvmfw_a" "$AOSP/pvmfw.img" 1048576

# BCB → recovery
[[ "$(stat -c %s "$MISC")" == 8192 ]] || { echo 'FAIL: misc size'; >&2; exit 1; }
[[ "$(LC_ALL=C tr -d '\000' <"$MISC")" == boot-recovery ]] || {
  echo 'FAIL: misc content' >&2
  exit 1
}
echo 'WRITE misc boot-recovery'
EDL w misc "$MISC" | tee "$LOGDIR/misc.write.log"

# Prefer slot a
EDL setslot a | tee "$LOGDIR/setslot-a.log" || true

sync
echo 'RESET'
EDL reset | tee "$LOGDIR/reset.log" || true
echo "PASS: ArtistAOSP bootchain written; reset issued. LOGDIR=$LOGDIR"
