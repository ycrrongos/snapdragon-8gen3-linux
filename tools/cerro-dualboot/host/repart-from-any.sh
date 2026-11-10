#!/usr/bin/env bash
# Accept fastboot OR recovery adb; flash good recovery; sideload repartition zip.
set +e
LOG=/tmp/cerro-dualboot-pipeline.log
STATUS=/tmp/cerro-dualboot-pipeline.status
REC=/mnt/data/LOA_Nubia_Z60U/recovery/orangefox/out/artist-recovery-root-sgdisk.img
ZIP=/mnt/data/LOA_Nubia_Z60U/tools/cerro-dualboot/host/cerro-repartition-sideload.zip
log(){ echo "$(date -Iseconds) $*" | tee -a "$LOG"; }
st(){ echo "$*" >"$STATUS"; log "STATUS $*"; }

has_fb(){ timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; }
has_rec(){ adb devices 2>/dev/null | awk '/\trecovery$/{exit 0} END{exit 1}'; }
has_side(){ adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}'; }

st waiting-any
log REPART_ANY_START
for i in $(seq 1 900); do
  if has_fb || has_rec || has_side || lsusb 2>/dev/null | grep -qiE '18d1:d00d|18d1:4ee0|18d1:d001'; then
    log "DETECT i=$i $(lsusb | grep -iE '18d1|05c6' || true)"
    break
  fi
  (( i % 30 == 0 )) && log "wait i=$i"
  sleep 1
done

# Normalize to known-good recovery via bootloader
if has_rec || has_side; then
  log "from recovery → bootloader"
  adb reboot bootloader >>"$LOG" 2>&1 || true
  for j in $(seq 1 60); do has_fb && break; sleep 1; done
fi

if ! has_fb; then
  log "no fastboot"
  st fail-no-fb
  exit 1
fi

st flash-recovery
timeout 90 fastboot flash recovery_a "$REC" >>"$LOG" 2>&1
timeout 90 fastboot flash recovery_b "$REC" >>"$LOG" 2>&1
timeout 30 fastboot reboot recovery >>"$LOG" 2>&1

for j in $(seq 1 90); do has_rec && break; has_fb && { log bounce; st bounce-fb; exit 3; }; sleep 1; done
if ! has_rec; then log "no recovery adb"; st fail-no-rec; exit 2; fi

log "recovery up → sideload"
adb reboot sideload >>"$LOG" 2>&1 || true
for j in $(seq 1 60); do has_side && break; sleep 1; done

st sideload-repart
log "sideload $ZIP"
adb sideload "$ZIP" >>"$LOG" 2>&1
rc=$?
log "sideload rc=$rc"
sleep 5

if has_rec || has_side; then adb reboot >>"$LOG" 2>&1 || true
elif has_fb; then timeout 20 fastboot reboot >>"$LOG" 2>&1 || true
fi

for j in $(seq 1 150); do
  adb devices 2>/dev/null | awk '/\tdevice$/{exit 0} END{exit 1}' && break
  sleep 2
done
bc=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
log "android bc=$bc sideload_rc=$rc"
[[ "$rc" -eq 0 ]] && st repartition-ok || st repartition-fail
exit "$rc"
