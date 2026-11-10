#!/system/bin/sh
# Android → Linux (same active slot): backup active boot → inactive, flash linux → active, reboot.
set -eu
BY=/dev/block/by-name
IMG=/data/adb/cerro/linux-boot.img
ALT=/data/cerro-dualboot/linux-boot.img
ALT2=/data/cerro-dualboot/linux-daily.img

if [ "$(id -u)" != 0 ]; then
  echo "ERROR: need root" >&2
  exit 1
fi

if [ -f "$IMG" ]; then
  :
elif [ -f "$ALT" ]; then
  IMG=$ALT
elif [ -f "$ALT2" ]; then
  IMG=$ALT2
else
  echo "ERROR: missing linux boot image at $IMG (or $ALT / $ALT2)" >&2
  exit 2
fi

# Determine active slot: _a / _b
SUFFIX=$(getprop ro.boot.slot_suffix 2>/dev/null || true)
case "$SUFFIX" in
  _a) ACT=a; INACT=b ;;
  _b) ACT=b; INACT=a ;;
  *)
    # bootctl fallback
    CUR=$(bootctl get-current-slot 2>/dev/null || true)
    case "$CUR" in
      0) ACT=a; INACT=b ;;
      1) ACT=b; INACT=a ;;
      *) echo "ERROR: cannot determine slot_suffix=$SUFFIX" >&2; exit 3 ;;
    esac
    ;;
esac

echo "=== Cerro: Android → Linux (boot swap, active=slot_$ACT) ==="
echo "dd boot_$ACT → boot_$INACT (backup Android)"
dd if="$BY/boot_$ACT" of="$BY/boot_$INACT" bs=4M status=none conv=fsync
echo "dd $IMG → boot_$ACT (Linux)"
dd if="$IMG" of="$BY/boot_$ACT" bs=4M status=none conv=fsync
sync
echo "OK: rebooting to Linux"
reboot
