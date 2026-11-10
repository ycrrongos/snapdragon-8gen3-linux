#!/usr/bin/env bash
# Wait for fastboot → temp-boot OP12 PBRP → adb root → do-repartition.sh
# Do NOT flash recovery partitions until PBRP is verified working on cerro.
set +e
LOG=/tmp/cerro-dualboot-pipeline.log
STATUS=/tmp/cerro-dualboot-pipeline.status
PBRP=${PBRP:-/mnt/data/LOA_Nubia_Z60U/recovery/ref/PBRP-OP12-20260203.img}
REPART=/mnt/data/LOA_Nubia_Z60U/tools/cerro-dualboot/recovery/do-repartition.sh
log(){ echo "$(date -Iseconds) $*" | tee -a "$LOG"; }
st(){ echo "$*" >"$STATUS"; log "STATUS $*"; }

[[ -f "$PBRP" ]] || { log "missing $PBRP"; exit 1; }
[[ -f "$REPART" ]] || { log "missing $REPART"; exit 1; }

st waiting-fastboot-pbrp
log "PBRP_WATCH start img=$PBRP"

for i in $(seq 1 900); do
  fb=$(timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{print;exit}')
  if [[ -n "$fb" ]] || lsusb 2>/dev/null | grep -q '18d1:d00d'; then
    log "DETECT fastboot [$fb]"
    break
  fi
  # if stuck in broken recovery with adb, reboot to bootloader
  if adb devices 2>/dev/null | awk '/\trecovery$|\tdevice$/{exit 0} END{exit 1}'; then
    log "adb present → bootloader"
    adb reboot bootloader >>"$LOG" 2>&1 || true
    sleep 5
    continue
  fi
  (( i % 30 == 0 )) && log "wait i=$i"
  sleep 1
done

if ! timeout 3 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
  st fail-no-fb
  exit 1
fi

st boot-pbrp
log "fastboot boot PBRP (temp, not flashing recovery_*)"
# Some ABLs reject boot of large images; retry once
if ! timeout 120 fastboot boot "$PBRP" >>"$LOG" 2>&1; then
  log "fastboot boot failed, retry"
  sleep 2
  timeout 120 fastboot boot "$PBRP" >>"$LOG" 2>&1 || {
    log "boot failed — try flash recovery as last resort? abort for safety"
    st fail-pbrp-boot
    exit 2
  }
fi

log "waiting PBRP adb recovery/device"
for j in $(seq 1 120); do
  if adb devices 2>/dev/null | awk '/\trecovery$|\tdevice$|\tsideload$/{exit 0} END{exit 1}'; then
    break
  fi
  if timeout 2 fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
    log "bounced to fastboot"
    st bounce-fb
    exit 3
  fi
  sleep 1
done

adb devices -l | tee -a "$LOG"
adb root >>"$LOG" 2>&1 || true
sleep 2
id=$(adb shell id 2>/dev/null | tr -d '\r')
log "id=$id"
props=$(adb shell 'getprop ro.twrp.boot; getprop ro.product.device; getprop ro.build.product; ls /sbin/sgdisk /system/bin/sgdisk /sbin/resize.f2fs 2>&1' 2>/dev/null)
log "props/tools: $props"

if ! echo "$id" | grep -q 'uid=0'; then
  log "no root yet — retry adb root"
  adb root >>"$LOG" 2>&1
  sleep 3
  id=$(adb shell id 2>/dev/null | tr -d '\r')
  log "id2=$id"
fi

if ! echo "$id" | grep -q 'uid=0'; then
  st fail-no-root
  log "PBRP up but no root — stop before repartition"
  exit 4
fi

# Ensure sgdisk available (push if missing)
if ! adb shell 'test -x /sbin/sgdisk -o -x /system/bin/sgdisk' 2>/dev/null; then
  log "pushing sgdisk"
  SG=/mnt/data/orangefox-cerro/out/target/product/cerro/recovery/root/system/bin/sgdisk
  adb push "$SG" /sbin/sgdisk >>"$LOG" 2>&1 || adb push "$SG" /system/bin/sgdisk >>"$LOG" 2>&1
  adb shell 'chmod 755 /sbin/sgdisk /system/bin/sgdisk 2>/dev/null' >>"$LOG" 2>&1
fi

st repartition
adb push "$REPART" /tmp/do-repartition.sh >>"$LOG" 2>&1
adb shell 'chmod 755 /tmp/do-repartition.sh; /tmp/do-repartition.sh' 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
log "repartition rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  st repartition-ok
else
  st repartition-fail
fi
exit "$rc"
