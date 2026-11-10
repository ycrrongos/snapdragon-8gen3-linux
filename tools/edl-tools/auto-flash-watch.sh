#!/usr/bin/env bash
# Persistent background watcher: flash boot when 9008 or answering fastboot appears.
#
#   auto-flash-watch.sh --daemon <boot.img>   # start in background
#   cat /tmp/cerro-auto-flash.status          # waiting|flashing-*|ok|fail-retry
#   tail -f /tmp/cerro-auto-flash.log
#
set -uo pipefail

ROOT=/mnt/data/LOA_Nubia_Z60U/tools/edl-tools
FLASH=$ROOT/flash-boot-any.sh
LOGDIR=${CERRO_FLASH_LOGDIR:-/tmp}
PIDFILE=$LOGDIR/cerro-auto-flash.pid
STATUS=$LOGDIR/cerro-auto-flash.status
LOG=$LOGDIR/cerro-auto-flash.log

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >>"$LOG"; }
set_status() { printf '%s\n' "$*" >"$STATUS"; }

daemonize=0
if [[ "${1:-}" == "--daemon" ]]; then
  daemonize=1
  shift
fi
IMG=${1:?usage: auto-flash-watch.sh [--daemon] <boot.img>}
[[ -f "$IMG" ]] || { echo "missing img: $IMG" >&2; exit 1; }

if [[ "$daemonize" -eq 1 ]]; then
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE") status=$(cat "$STATUS" 2>/dev/null || true)"
    exit 0
  fi
  # New session so Cursor/IDE shell teardown cannot kill us.
  setsid "$0" "$IMG" </dev/null >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  set_status "waiting img=$IMG"
  echo "started pid=$! log=$LOG status=$STATUS"
  exit 0
fi

echo $$ >"$PIDFILE"
# Do not clobber a successful "ok ..." status on EXIT (was breaking observe).
trap 'st=$(cat "$STATUS" 2>/dev/null || true); [[ "$st" == ok* ]] || set_status "stopped"; rm -f "$PIDFILE"' EXIT

log "watch start img=$IMG pid=$$"
set_status "waiting img=$IMG"

have_9008() { lsusb 2>/dev/null | grep -q '05c6:9008'; }
have_fb() { lsusb 2>/dev/null | grep -q '18d1:d00d'; }
fb_ok() { timeout 5 fastboot getvar product 2>/dev/null | grep -qi product; }

while true; do
  if have_9008; then
    log "DETECT 9008 — flashing"
    set_status "flashing-9008 img=$IMG"
    if "$FLASH" "$IMG" >>"$LOG" 2>&1; then
      log "FLASH_OK"
      set_status "ok img=$IMG ts=$(date -Iseconds)"
      exit 0
    fi
    log "FLASH_FAIL — wait for 9008 to drop, then retry"
    set_status "fail-retry img=$IMG"
    while have_9008; do sleep 2; done
    log "9008 gone — waiting for next entry"
    set_status "waiting img=$IMG"
  fi

  if have_fb && fb_ok; then
    log "DETECT answering fastboot — flashing"
    set_status "flashing-fastboot img=$IMG"
    if "$FLASH" "$IMG" >>"$LOG" 2>&1; then
      log "FLASH_OK"
      set_status "ok img=$IMG ts=$(date -Iseconds)"
      exit 0
    fi
    log "FLASH_FAIL via fastboot — wait for d00d to drop"
    set_status "fail-retry img=$IMG"
    while have_fb; do sleep 2; done
    set_status "waiting img=$IMG"
  fi

  sleep 2
done
