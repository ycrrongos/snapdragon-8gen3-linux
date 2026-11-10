#!/usr/bin/env bash
# Flash InfinityX images via fastbootd. Does NOT wipe until --wipe.
# Usage: flash-infinityx-fastbootd.sh [--wipe] [/path/to/product/cerro]
set -euo pipefail
FB="${FB:-fastboot}"
WIPE=0
IX=/mnt/data/InfinityX_cerro/InfinityX_cerro_src/out/target/product/cerro
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe) WIPE=1; shift ;;
    *) IX="$1"; shift ;;
  esac
done
cd "$IX"
"$FB" devices
"$FB" getvar is-userspace 2>&1 | tee /tmp/fb-userspace.txt
grep -q 'yes' /tmp/fb-userspace.txt || {
  echo "Not in fastbootd. From bootloader: fastboot reboot fastboot"
  exit 1
}
for p in boot init_boot dtbo recovery pvmfw vendor_boot vbmeta vbmeta_system; do
  [[ -f ${p}.img ]] || continue
  echo "==== flash $p ===="
  "$FB" flash "$p" "${p}.img"
done
"$FB" snapshot-update cancel || true
# both slots for boot-critical
for s in a b; do
  for p in boot init_boot dtbo vendor_boot vbmeta; do
    [[ -f ${p}.img ]] || continue
    "$FB" flash ${p}_${s} "${p}.img" 2>/dev/null || true
  done
done
for p in odm product system system_dlkm system_ext vendor vendor_dlkm; do
  [[ -f ${p}.img ]] || continue
  echo "==== flash $p ===="
  "$FB" flash "$p" "${p}.img"
done
if [[ "$WIPE" = 1 ]]; then
  echo "==== wipe userdata/metadata (Android needs empty userdata) ===="
  "$FB" erase userdata || "$FB" format:f2fs userdata || true
  "$FB" erase metadata || "$FB" format:f2fs metadata || true
else
  echo "NOTE: skipped wipe. Android may fail if userdata is still pmOS ext4."
  echo "Re-run with --wipe ONLY after linux-kde backup is complete (gzip -t OK)."
fi
echo "Done. reboot: $FB reboot"
