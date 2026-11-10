#!/usr/bin/env bash
# On fastboot: flash good artist-root recovery → sideload repartition zip → reboot Android.
set +e
LOG=/tmp/cerro-dualboot-pipeline.log
STATUS=/tmp/cerro-dualboot-pipeline.status
REC=/mnt/data/LOA_Nubia_Z60U/recovery/orangefox/out/artist-recovery-root-sgdisk.img
ZIP=/mnt/data/LOA_Nubia_Z60U/tools/cerro-dualboot/host/cerro-repartition-sideload.zip
log(){ echo "$(date -Iseconds) $*" | tee -a "$LOG"; }
st(){ echo "$*" >"$STATUS"; log "STATUS $*"; }

st waiting-fastboot-repart
log REPART_WATCH_START
for i in $(seq 1 900); do
  fb=$(timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{print;exit}')
  usb=$(lsusb 2>/dev/null | grep -i '18d1:d00d' || true)
  if [[ -n "$fb" || -n "$usb" ]]; then
    log "DETECT fb=[$fb] usb=[$usb]"
    st flash-recovery
    timeout 60 fastboot flash recovery_a "$REC" >>"$LOG" 2>&1
    timeout 60 fastboot flash recovery_b "$REC" >>"$LOG" 2>&1
    timeout 20 fastboot reboot recovery >>"$LOG" 2>&1
    for j in $(seq 1 90); do
      adb devices 2>/dev/null | awk '/\trecovery$/{exit 0} END{exit 1}' && break
      sleep 1
    done
    log "recovery adb; requesting sideload"
    adb reboot sideload >>"$LOG" 2>&1 || true
    for j in $(seq 1 60); do
      adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}' && break
      sleep 1
    done
    if ! adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}'; then
      log "sideload mode fail — try adb sideload from recovery anyway"
    fi
    st sideload-repart
    log "sideload $ZIP"
    adb sideload "$ZIP" >>"$LOG" 2>&1
    rc=$?
    log "sideload rc=$rc"
    sleep 3
    # back to android
    if adb devices 2>/dev/null | awk '/\trecovery$|\tsideload$/{exit 0} END{exit 1}'; then
      adb reboot >>"$LOG" 2>&1 || true
    elif timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
      timeout 20 fastboot reboot >>"$LOG" 2>&1 || true
    fi
    for j in $(seq 1 120); do
      adb devices 2>/dev/null | awk '/\tdevice$/{exit 0} END{exit 1}' && break
      sleep 2
    done
    bc=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    log "after repart android bc=$bc"
    # verify GPT has cerro_linux if we get root later; for now check via recovery next time
    if [[ "$rc" -eq 0 ]]; then st repartition-sideload-ok; else st repartition-sideload-fail; fi
    exit "$rc"
  fi
  if (( i % 20 == 0 )); then log "wait fastboot i=$i"; fi
  sleep 1
done
st timeout
exit 1
