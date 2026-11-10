#!/usr/bin/env bash
# Capture Android voice-call ADSP/AGM/GPR breadcrumbs while a real call is up.
# Run on host with adb (KSU/root). Does NOT place the call — user must dial/answer.
# Output: /tmp/cerro-android-voice-*.log on host (+ mirrored under notes/ if CERRO_SAVE=1).
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-/tmp/cerro-android-voice-$TS}"
mkdir -p "$OUT"

adb wait-for-device
adb shell "su -c 'id'" >/dev/null

echo "== pre: processes / nodes ==" | tee "$OUT/pre.txt"
adb shell "su -c '
ps -A | grep -iE \"agm|audio|voice|c2audio|qti.audio|adsprpcd|audioadsprpcd\" || true
ls -la /dev/snd /dev/agm* /dev/gpr* /dev/audio_* 2>/dev/null || true
getprop | grep -iE \"audio|voice|voip|call\" | head -80
'" | tee -a "$OUT/pre.txt"

echo "== logcat clear + start (broad audio/voice; no *:S) ==" | tee "$OUT/meta.txt"
adb logcat -c || true
# Do NOT use '*:S' — many QTI voice tags are nonstandard and get silenced.
adb logcat -v threadtime >"$OUT/logcat-all.txt" &
LC_PID=$!
echo "logcat_pid=$LC_PID" | tee -a "$OUT/meta.txt"
echo "Dial or answer a call NOW. Capture runs ${DUR:-90}s…" | tee -a "$OUT/meta.txt"
sleep "${DUR:-90}"
kill "$LC_PID" 2>/dev/null || true
wait "$LC_PID" 2>/dev/null || true
# Compact hit extract for humans
rg -n -i "VSID|VOICE_CALL|voice_call|CVD|CVS|agm_graph|graph_id|PAL_STREAM_VOICE|codec2codec|SESSION_VOICE|VoiceCall" \
  "$OUT/logcat-all.txt" >"$OUT/logcat-voice.txt" || true

echo "== during/after dumps ==" | tee "$OUT/post.txt"
adb shell "su -c '
dumpsys media.audio_flinger 2>/dev/null | head -200
dumpsys audio 2>/dev/null | head -200
ls /proc/asound 2>/dev/null
# AGM graphs if node exists
for d in /sys/kernel/debug/agm /d/agm /sys/kernel/debug/audio; do
  [ -d \"\$d\" ] || continue
  echo === \$d ===
  find \"\$d\" -type f 2>/dev/null | head -80
done
'" | tee -a "$OUT/post.txt"

# Extract likely module / VSID / graph ids
rg -n "VSID|voice_call|VOICE_CALL|graph_id|module_id|CVD|CVS|codec2codec|SID" \
  "$OUT/logcat-voice.txt" >"$OUT/hits.txt" || true
wc -l "$OUT"/* | tee "$OUT/meta-wc.txt"
echo "DONE $OUT"
if [[ "${CERRO_SAVE:-0}" == 1 ]]; then
  dest="/mnt/data/LOA_Nubia_Z60U/notes/android-voice-refs/$TS"
  mkdir -p "$dest"
  cp -a "$OUT"/. "$dest/"
  echo "saved $dest"
fi
