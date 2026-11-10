#!/usr/bin/env bash
# Wait for fastboot, then sideload/fastbootd flash Aurora + wipe + verify.
set +e
LOG=/tmp/cerro-dualboot-pipeline.log
STATUS=/tmp/cerro-dualboot-pipeline.status
AURORA_ZIP=/mnt/data/ArtistAOSP/source/out/target/product/cerro/voltage-6.1-cerro-20261011-1148-UNOFFICIAL.zip
ARTIST_REC=/mnt/data/ArtistAOSP/source/out/target/product/cerro/recovery.img
OUT=/mnt/data/ArtistAOSP/source/out/target/product/cerro

log() { echo "$(date -Iseconds) $*" | tee -a "$LOG"; }
st() { echo "$*" >"$STATUS"; log "STATUS $*"; }

st waiting-fastboot
log WATCH_START

for i in $(seq 1 600); do
  usb=$(lsusb 2>/dev/null | grep -iE '18d1:|05c6:9008|19d2:' || true)
  fb=$(timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{print; exit}')
  if [[ -n "$fb" ]] || echo "$usb" | grep -q '18d1:d00d'; then
    log "DETECT fb=[$fb] usb=[$usb]"
    st flashing
    timeout 60 fastboot flash recovery_a "$ARTIST_REC" >>"$LOG" 2>&1
    timeout 60 fastboot flash recovery_b "$ARTIST_REC" >>"$LOG" 2>&1
    timeout 20 fastboot --set-active=a >>"$LOG" 2>&1
    timeout 20 fastboot reboot recovery >>"$LOG" 2>&1
    log "rebooted recovery"

    mode=""
    for j in $(seq 1 90); do
      if adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}'; then mode=sideload; break; fi
      if adb devices 2>/dev/null | awk '/\trecovery$/{exit 0} END{exit 1}'; then mode=recovery; break; fi
      if timeout 2 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
        mode=fastbootd_fallback
        break
      fi
      sleep 1
    done
    log "mode=$mode"

    if [[ "$mode" == recovery ]]; then
      adb reboot sideload >>"$LOG" 2>&1 || true
      for j in $(seq 1 60); do
        adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}' && mode=sideload && break
        sleep 1
      done
      log "after reboot sideload mode=$mode"
    fi

    if [[ "$mode" == sideload ]]; then
      st sideload
      log "SIDELOAD start $(basename "$AURORA_ZIP")"
      adb sideload "$AURORA_ZIP" >>"$LOG" 2>&1
      log "SIDELOAD done rc=$?"
      sleep 3
      adb reboot bootloader >>"$LOG" 2>&1 || true
      sleep 8
    fi

    # Prefer fastbootd for wipe + ensure images (also covers sideload miss / fallback)
    if timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
      timeout 30 fastboot reboot fastboot >>"$LOG" 2>&1 || true
      sleep 10
    fi
    for j in $(seq 1 90); do
      timeout 3 fastboot getvar is-userspace 2>&1 | grep -qi yes && break
      sleep 1
    done

    if timeout 3 fastboot getvar is-userspace 2>&1 | grep -qi yes; then
      st fastbootd-flash
      log "FASTBOOTD flash + wipe"
      timeout 30 fastboot --set-active=a >>"$LOG" 2>&1
      for p in boot vendor_boot init_boot dtbo vbmeta vbmeta_system recovery; do
        [[ -f "$OUT/${p}.img" ]] || continue
        timeout 180 fastboot flash "${p}_a" "$OUT/${p}.img" >>"$LOG" 2>&1
        timeout 180 fastboot flash "${p}_b" "$OUT/${p}.img" >>"$LOG" 2>&1
      done
      for p in system system_ext product vendor odm; do
        [[ -f "$OUT/${p}.img" ]] || continue
        log "flash $p"
        timeout 900 fastboot flash "$p" "$OUT/${p}.img" >>"$LOG" 2>&1 || log "warn flash $p"
      done
      timeout 180 fastboot -w >>"$LOG" 2>&1
      timeout 30 fastboot reboot >>"$LOG" 2>&1
      log "rebooted after fastbootd"
    fi

    st verify-android
    for j in $(seq 1 200); do
      if adb devices 2>/dev/null | awk '/\tdevice$/{exit 0} END{exit 1}'; then
        bc=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [[ "$bc" == 1 ]] && break
      fi
      sleep 2
    done
    bc=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    disp=$(adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')
    slot=$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
    log "ANDROID_UP bc=$bc slot=$slot disp=$disp"
    if [[ "$bc" == 1 ]]; then st android-ok; else st fail-android-boot; fi
    exit 0
  fi
  if (( i % 15 == 0 )); then log "still waiting i=$i usb=[$usb]"; fi
  sleep 1
done
st timeout
log TIMEOUT
exit 1
