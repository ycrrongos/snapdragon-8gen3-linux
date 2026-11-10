#!/usr/bin/env bash
# Dump WSA / SoundWire golden sample on AOSP userdebug while speakers are alive.
# Compare against notes/bisect-logs/linux-s5fq-wsa-baseline-*.txt
#
# Usage:
#   tools/edl-tools/aosp-wsa-gold-dump.sh [out.txt]
#
# Needs: adb device = cerro/PJD110 (not OnePlus). Prefer USB.
set -euo pipefail

OUT="${1:-/mnt/data/LOA_Nubia_Z60U/notes/bisect-logs/aosp-wsa-gold-$(date +%Y%m%d-%H%M%S).txt}"

pick_serial() {
  local s line prod
  while read -r line; do
    s=$(awk '{print $1}' <<<"$line")
    [[ -n "$s" && "$s" != "List" ]] || continue
    prod=$(adb -s "$s" shell 'getprop ro.product.device; getprop ro.product.name' 2>/dev/null | tr '\n' ' ')
    # Cerro AOSP / stock-ish: cerro, PJD110, OP5929L1 (Z60U)
    if grep -qiE 'cerro|PJD110|OP5929|nubia|Z60' <<<"$prod"; then
      echo "$s"
      return 0
    fi
  done < <(adb devices | awk 'NR>1 && /device$/{print}')
  return 1
}

serial=$(pick_serial || true)
if [[ -z "${serial:-}" ]]; then
  echo "ERROR: no cerro/PJD110 adb device (ignore OnePlus etc.)" >&2
  adb devices -l >&2 || true
  exit 1
fi
ADB=(adb -s "$serial")
echo "Using serial=$serial"

"${ADB[@]}" root >/dev/null 2>&1 || true
sleep 1
"${ADB[@]}" wait-for-device
"${ADB[@]}" remount >/dev/null 2>&1 || true

# Wake + play a short UI sound so amps/SWR should be active
"${ADB[@]}" shell '
setenforce 0 2>/dev/null || true
input keyevent KEYCODE_WAKEUP 2>/dev/null || true
settings put system screen_off_timeout 300000 2>/dev/null || true
# best-effort playback
( toybox timeout 4 cmd media_session dispatch play 2>/dev/null & )
for f in /system/media/audio/ui/Effect_Tick.ogg \
         /system/product/media/audio/ui/Effect_Tick.ogg \
         /system/media/audio/ui/VideoRecord.ogg; do
  if [ -f "$f" ]; then
    toybox timeout 3 media play "$f" >/dev/null 2>&1 &
    break
  fi
done
sleep 1
' || true

# Physical bases (SM8650)
#   WSA SWR master  0x06b10000
#   WSA macro       0x06b00000
#   WSA2 SWR        0x06ab0000
#   WSA2 macro      0x06aa0000
#   RX SWR          0x06ad0000

read_devmem() {
  local addr="$1"
  "${ADB[@]}" shell "devmem $addr 32 2>/dev/null || /vendor/bin/devmem $addr 32 2>/dev/null || /system/bin/devmem $addr 32 2>/dev/null || echo NA"
}

dump_block() {
  local base="$1" name="$2"
  echo "=== MMIO $name @ $base ==="
  if ! "${ADB[@]}" shell 'ls -l /dev/mem 2>/dev/null; ls -l /dev/mem' 2>/dev/null | grep -q mem; then
    echo "(no /dev/mem — skip raw MMIO)"
    return 0
  fi
  local off
  for off in 0x000 0x004 0x008 0x00c 0x010 0x014 0x018 0x100 0x104 \
             0x500 0x530 0x534 0x538 0x53c 0x540 0x544 \
             0x4000 0x5040 0x5060 0x5064; do
    local a
    a=$(printf '0x%x' $((base + off)))
    echo -n "  $off: "
    read_devmem "$a"
  done
}

{
  echo "=== AOSP WSA / SoundWire gold dump $(date -Iseconds) ==="
  echo "serial=$serial"
  "${ADB[@]}" shell 'getprop ro.build.display.id; getprop ro.product.name; getprop ro.product.device; getprop ro.boot.slot_suffix; uname -a'
  echo
  echo "=== audio service / cards ==="
  "${ADB[@]}" shell '
dumpsys media.audio_flinger 2>/dev/null | head -40
echo ---
ls /proc/asound 2>/dev/null
cat /proc/asound/cards 2>/dev/null
echo ---
pidof audioserver; pidof vendor.qti.hardware.audio*
' || true
  echo
  echo "=== platform / soundwire-ish devices ==="
  "${ADB[@]}" shell '
ls -d /sys/devices/platform/soc/6b* /sys/devices/platform/soc/6a* 2>/dev/null | head -40
ls /sys/bus/platform/devices | grep -iE "wsa|swr|lpass|sound" | head -40
ls /sys/bus/soundwire/devices 2>/dev/null | head
' || true
  echo
  echo "=== debugfs mount + pinctrl LPASS gpio10/11/15/16/21 ==="
  "${ADB[@]}" shell '
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
for d in /sys/kernel/debug/pinctrl/*; do
  [ -f "$d/pinmux-pins" ] || continue
  echo DIR=$d
  grep -E "gpio(10|11|15|16|21)|GPIO_77|gpio77" "$d/pinmux-pins" 2>/dev/null || true
done
' || true
  echo
  echo "=== clk / regulator (WSA-ish) ==="
  "${ADB[@]}" shell '
cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE "wsa|swr|lpass" | head -40
echo ---
for r in /sys/class/regulator/regulator.*; do
  n=$(cat $r/name 2>/dev/null) || continue
  echo "$n" | grep -qiE "l15b|l3c|wsa|spkr|audio" || continue
  echo "$n state=$(cat $r/state 2>/dev/null) uV=$(cat $r/microvolts 2>/dev/null)"
done
' || true
  echo
  echo "=== regmap heads (if any) ==="
  "${ADB[@]}" shell '
ls /sys/kernel/debug/regmap 2>/dev/null | head -40
for d in /sys/kernel/debug/regmap/*wsa* /sys/kernel/debug/regmap/*6b00000* /sys/kernel/debug/regmap/*6b10000*; do
  [ -d "$d" ] || continue
  echo DIR=$d
  head -16 "$d/registers" 2>/dev/null || true
done
' || true
  echo
  dump_block 0x06b10000 "WSA_SWR0"
  dump_block 0x06b00000 "WSA_MACRO"
  dump_block 0x06ab0000 "WSA2_SWR3"
  dump_block 0x06aa0000 "WSA2_MACRO"
  dump_block 0x06ad0000 "RX_SWR1"
  echo
  echo "=== dmesg audio/swr/wsa (tail) ==="
  "${ADB[@]}" shell 'dmesg 2>/dev/null | grep -iE "swr|soundwire|wsa|spf|lpass|snd" | tail -80' || true
  echo
  echo "=== logcat audio (brief) ==="
  "${ADB[@]}" shell 'logcat -d -b all 2>/dev/null | grep -iE "WSA|SWR|soundwire|audio_hw|PAL:|AGM:" | tail -60' || true
  echo
  echo "=== DONE ==="
} | tee "$OUT"

echo "Wrote $OUT"
