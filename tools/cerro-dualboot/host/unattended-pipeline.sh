#!/usr/bin/env bash
# Unattended cerro dual-boot pipeline:
#   1) wait for phone USB
#   2) sideload Aurora OTA zip (+ wipe userdata)
#   3) verify Android up
#   4) flash rooted Artist recovery + repartition (userdata~200G + cerro_linux)
#   5) restore debian-root onto cerro_linux (best-effort)
#
#   unattended-pipeline.sh --daemon
#   tail -f /tmp/cerro-dualboot-pipeline.log
#   cat /tmp/cerro-dualboot-pipeline.status
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AURORA_ZIP="${AURORA_ZIP:-/mnt/data/ArtistAOSP/source/out/target/product/cerro/voltage-6.1-cerro-20261011-1148-UNOFFICIAL.zip}"
ARTIST_REC="${ARTIST_REC:-/mnt/data/ArtistAOSP/source/out/target/product/cerro/recovery.img}"
ARTIST_ROOT_REC="${ARTIST_ROOT_REC:-$ROOT/recovery/orangefox/out/artist-recovery-root-sgdisk.img}"
REPART="$ROOT/tools/cerro-dualboot/recovery/do-repartition.sh"
DEBIAN_TAR="${DEBIAN_TAR:-$ROOT/backups/debian-native-20260817/debian-root.tar.zst}"
ENTER9008="$ROOT/tools/edl-tools/enter-9008-hand.sh"

LOG=/tmp/cerro-dualboot-pipeline.log
STATUS=/tmp/cerro-dualboot-pipeline.status
PIDFILE=/tmp/cerro-dualboot-pipeline.pid

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }
set_status() { printf '%s\n' "$*" >"$STATUS"; log "STATUS $*"; }

has_fb() { fastboot devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; }
has_adb_device() { adb devices 2>/dev/null | awk '/\tdevice$/{exit 0} END{exit 1}'; }
has_adb_recovery() { adb devices 2>/dev/null | awk '/\trecovery$/{exit 0} END{exit 1}'; }
has_adb_sideload() { adb devices 2>/dev/null | awk '/\tsideload$/{exit 0} END{exit 1}'; }
has_9008() { lsusb 2>/dev/null | grep -q '05c6:9008'; }
has_any_phone() { lsusb 2>/dev/null | grep -qiE '18d1:|05c6:9008|19d2:0112'; }
has_servo() { [[ -d /dev/serial/by-id ]] && compgen -G '/dev/serial/by-id/*Espressif*' >/dev/null; }

wait_fb() {
  local i
  for i in $(seq 1 "${1:-90}"); do has_fb && return 0; sleep 1; done
  return 1
}
wait_adb_device() {
  local i
  for i in $(seq 1 "${1:-180}"); do has_adb_device && return 0; sleep 1; done
  return 1
}
wait_adb_recovery() {
  local i
  for i in $(seq 1 "${1:-90}"); do has_adb_recovery && return 0; sleep 1; done
  return 1
}

flash_recovery_both() {
  local img=$1
  [[ -f "$img" ]] || { log "missing recovery $img"; return 1; }
  fastboot flash recovery_a "$img" || return 1
  fastboot flash recovery_b "$img" || return 1
}

to_bootloader() {
  if has_fb; then return 0; fi
  if has_adb_device || has_adb_recovery; then
    adb reboot bootloader || true
    wait_fb 60 && return 0
  fi
  if has_9008; then
    log "in 9008 — need bootloader via firehose/reset not automated here"
    return 1
  fi
  return 1
}

# --- Phase: get phone into Artist recovery (known-good) ---
enter_artist_recovery() {
  set_status "enter-artist-recovery"
  to_bootloader || return 1
  flash_recovery_both "$ARTIST_REC" || return 1
  fastboot reboot recovery || return 1
  wait_adb_recovery 90 || return 1
  log "Artist recovery up"
  return 0
}

# --- Phase: sideload Aurora zip ---
sideload_aurora() {
  set_status "sideload-aurora"
  [[ -f "$AURORA_ZIP" ]] || { log "missing $AURORA_ZIP"; return 1; }

  if has_adb_device; then
    log "Android up → reboot sideload"
    adb reboot sideload || adb reboot recovery || true
  elif has_fb; then
    enter_artist_recovery || return 1
  elif ! has_adb_recovery && ! has_adb_sideload; then
    enter_artist_recovery || return 1
  fi

  # From recovery, request sideload mode
  if has_adb_recovery && ! has_adb_sideload; then
    log "recovery → sideload"
    adb shell "recovery --sideload" 2>/dev/null || true
    adb reboot sideload 2>/dev/null || true
    # stock UI path: apply update from ADB
    for i in $(seq 1 45); do
      has_adb_sideload && break
      # some builds expose "sideload" after twrp/stock command
      adb devices 2>/dev/null | tee -a "$LOG" | awk '/sideload/{exit 0} END{exit 1}' && break
      sleep 1
    done
  fi

  if ! has_adb_sideload; then
    # Fallback: reboot to sideload from whatever state
    if has_adb_recovery || has_adb_device; then
      adb reboot sideload 2>/dev/null || true
    fi
    for i in $(seq 1 60); do has_adb_sideload && break; sleep 1; done
  fi

  if ! has_adb_sideload; then
    log "sideload mode not reached — fallback fastbootd image flash"
    return 2
  fi

  log "sideloading $(basename "$AURORA_ZIP") ($(du -h "$AURORA_ZIP" | awk '{print $1}'))"
  # sideload can take 10+ min
  if ! adb sideload "$AURORA_ZIP" >>"$LOG" 2>&1; then
    log "adb sideload failed"
    return 1
  fi
  log "sideload finished"
  return 0
}

wipe_userdata() {
  set_status "wipe-userdata"
  # After sideload device may be recovery or rebooting
  sleep 5
  if has_adb_recovery; then
    adb shell "recovery --wipe_data" 2>/dev/null || true
    adb shell twrp wipe data 2>/dev/null || true
  fi
  if to_bootloader; then
    # userspace fastbootd preferred for -w
    fastboot reboot fastboot 2>/dev/null || true
    sleep 5
    if fastboot devices 2>/dev/null | grep -q .; then
      if fastboot getvar is-userspace 2>&1 | grep -qi 'yes'; then
        fastboot -w >>"$LOG" 2>&1 || true
      else
        # bootloader: erase userdata/metadata
        fastboot erase userdata >>"$LOG" 2>&1 || true
        fastboot erase metadata >>"$LOG" 2>&1 || true
      fi
    fi
  fi
  log "wipe attempted"
}

boot_and_verify_android() {
  set_status "verify-android"
  if has_fb; then
    fastboot --set-active=a >>"$LOG" 2>&1 || true
    fastboot reboot || true
  elif has_adb_recovery || has_adb_sideload; then
    adb reboot || true
  fi
  wait_adb_device 240 || { log "Android did not come up"; return 1; }
  local i prop slot
  for i in $(seq 1 120); do
    prop=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [[ "$prop" == "1" ]] && break
    sleep 2
  done
  prop=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  slot=$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
  local disp
  disp=$(adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')
  log "ANDROID_UP boot_completed=$prop slot=$slot display=$disp"
  [[ "$prop" == "1" ]] || return 1
  return 0
}

# Fallback: full fastbootd flash of out/ images (same as prior working path)
fastbootd_flash_aurora_imgs() {
  set_status "fastbootd-flash-imgs"
  local OUT=/mnt/data/ArtistAOSP/source/out/target/product/cerro
  to_bootloader || return 1
  fastboot reboot fastboot || true
  sleep 8
  # wait userspace fastbootd
  local i
  for i in $(seq 1 60); do
    fastboot getvar is-userspace 2>&1 | grep -qi yes && break
    sleep 1
  done
  fastboot --set-active=a || true
  for p in boot vendor_boot init_boot dtbo vbmeta vbmeta_system recovery; do
    [[ -f "$OUT/${p}.img" ]] || continue
    fastboot flash ${p}_a "$OUT/${p}.img" >>"$LOG" 2>&1 || true
    fastboot flash ${p}_b "$OUT/${p}.img" >>"$LOG" 2>&1 || true
  done
  for p in system system_ext product vendor odm system_dlkm vendor_dlkm; do
    [[ -f "$OUT/${p}.img" ]] || continue
    fastboot flash "$p" "$OUT/${p}.img" >>"$LOG" 2>&1 || log "warn flash $p failed"
  done
  fastboot -w >>"$LOG" 2>&1 || true
  fastboot reboot || true
  return 0
}

repartition_phase() {
  set_status "repartition"
  [[ -f "$ARTIST_ROOT_REC" ]] || { log "missing $ARTIST_ROOT_REC"; return 1; }
  to_bootloader || return 1
  flash_recovery_both "$ARTIST_ROOT_REC" || return 1
  fastboot reboot recovery || return 1
  wait_adb_recovery 90 || return 1
  adb root >>"$LOG" 2>&1 || true
  sleep 2
  local id
  id=$(adb shell id 2>/dev/null | tr -d '\r')
  log "recovery id=$id"
  if ! echo "$id" | grep -q 'uid=0'; then
    log "no root in recovery — cannot repartition safely"
    return 1
  fi
  adb push "$REPART" /tmp/do-repartition.sh >>"$LOG" 2>&1 || return 1
  adb shell "chmod 755 /tmp/do-repartition.sh; /tmp/do-repartition.sh" >>"$LOG" 2>&1 || {
    log "repartition script failed"
    return 1
  }
  log "repartition OK"
  return 0
}

restore_debian_phase() {
  set_status "restore-debian"
  [[ -f "$DEBIAN_TAR" ]] || { log "missing $DEBIAN_TAR"; return 1; }
  has_adb_recovery || wait_adb_recovery 30 || return 1
  adb root >>"$LOG" 2>&1 || true
  adb shell "mkdir -p /tmp/cerro_linux_mnt; mount /dev/block/by-name/cerro_linux /tmp/cerro_linux_mnt || mount /dev/block/sda13 /tmp/cerro_linux_mnt" >>"$LOG" 2>&1 || return 1
  log "streaming debian-root.tar.zst → cerro_linux (slow)"
  # Host decompress + adb exec-in; large transfer
  if command -v zstd >/dev/null; then
    zstd -dc "$DEBIAN_TAR" | adb exec-out "tar -x -C /tmp/cerro_linux_mnt" >>"$LOG" 2>&1 || {
      # fallback: push then extract (needs free space on /tmp — may fail)
      log "pipe extract failed, trying push"
      return 1
    }
  else
    log "zstd missing on host"
    return 1
  fi
  adb shell "mkdir -p /tmp/cerro_linux_mnt/debian-root; ln -sfn debian-root/sbin/init /tmp/cerro_linux_mnt/sbin/init 2>/dev/null; sync; umount /tmp/cerro_linux_mnt" >>"$LOG" 2>&1 || true
  log "debian restore attempted"
  return 0
}

try_servo_9008() {
  has_servo || return 1
  [[ -x "$ENTER9008" ]] || return 1
  set_status "servo-9008"
  log "servo present — enter 9008"
  HOLD_S=45 "$ENTER9008" >>"$LOG" 2>&1 || true
}

main_loop() {
  set_status "waiting-phone"
  log "pipeline start aurora=$AURORA_ZIP"
  local n=0
  while true; do
    n=$((n + 1))
    if has_any_phone || has_fb || has_adb_device || has_adb_recovery || has_adb_sideload; then
      log "phone USB detected (n=$n)"
      break
    fi
    if (( n % 30 == 0 )); then
      try_servo_9008 || true
      log "still waiting phone… (n=$n)"
    fi
    sleep 2
  done

  # Phase 1: Aurora sideload (or fastbootd fallback)
  local rc=0
  sideload_aurora || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    fastbootd_flash_aurora_imgs || { set_status "fail-flash"; exit 1; }
  elif [[ "$rc" -ne 0 ]]; then
    log "sideload failed rc=$rc — trying fastbootd fallback"
    fastbootd_flash_aurora_imgs || { set_status "fail-flash"; exit 1; }
  fi

  wipe_userdata
  boot_and_verify_android || { set_status "fail-android-boot"; exit 1; }
  set_status "android-ok"

  # Phase 2: repartition for dual-boot
  if repartition_phase; then
    restore_debian_phase || log "debian restore deferred"
    set_status "repartition-ok"
  else
    set_status "android-ok-repartition-pending"
    log "repartition pending — fix recovery root later"
  fi

  # Return to Android for daily use / further tooling
  if has_adb_recovery; then adb reboot || true; fi
  wait_adb_device 180 || true
  set_status "done ts=$(date -Iseconds)"
  log "pipeline done"
}

if [[ "${1:-}" == "--daemon" ]]; then
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE") status=$(cat "$STATUS" 2>/dev/null || true)"
    exit 0
  fi
  : >"$LOG"
  setsid "$0" </dev/null >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  set_status "waiting-phone"
  echo "started pid=$! log=$LOG status=$STATUS"
  exit 0
fi

echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
main_loop
