#!/bin/sh
# Mark the current A/B slot successful so ABL retry/unbootable counters clear.
# Must run after boot_* partitions are visible; preferred trigger: SDDM greeter up
# (cerro-slot-success.service). Also used by qbootctl.service drop-in.
set -eu
export LC_ALL=C

log() { echo "cerro-qboot-mark-success: $*" >&2; }

i=0
while [ "$i" -lt 60 ]; do
  active=$(/usr/bin/qbootctl -a 2>&1 | sed -n 's/^Active slot: //p' | tail -n 1)
  current=$(/usr/bin/qbootctl -c 2>&1 | sed -n 's/^Current slot: //p' | tail -n 1)
  case "$active:$current" in
    _a:_a|_b:_b)
      log "active=$active current=$current; marking successful (clears ABL retry)"
      /usr/bin/qbootctl -m
      log "$(/usr/bin/qbootctl -c 2>&1 | tr '\n' ' ')"
      log "$(/usr/bin/qbootctl -a 2>&1 | tr '\n' ' ')"
      exit 0
      ;;
  esac
  log "slots not ready or disagree (active=${active:-unknown}, current=${current:-unknown}); retry $((i + 1))/60"
  sleep 2
  i=$((i + 1))
done

log "timed out waiting for consistent A/B slot metadata"
exit 1
