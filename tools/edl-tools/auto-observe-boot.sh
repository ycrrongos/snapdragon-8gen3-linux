#!/usr/bin/env bash
# After auto-flash-watch reports ok, observe boot PASS/FAIL and capture ACM markers.
#
#   auto-observe-boot.sh --daemon [label]
#   cat /tmp/cerro-boot-observe.status
#   cat /tmp/cerro-boot-observe.markers
#
set -uo pipefail

LOGDIR=${CERRO_FLASH_LOGDIR:-/tmp}
FLASH_STATUS=$LOGDIR/cerro-auto-flash.status
PIDFILE=$LOGDIR/cerro-boot-observe.pid
STATUS=$LOGDIR/cerro-boot-observe.status
MARKERS=$LOGDIR/cerro-boot-observe.markers
LOG=$LOGDIR/cerro-boot-observe.log
TSV=${CERRO_BISECT_TSV:-/mnt/data/LOA_Nubia_Z60U/notes/bisect-logs/map-bisect.tsv}

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >>"$LOG"; }
set_status() { printf '%s\n' "$*" >"$STATUS"; }

daemonize=0
if [[ "${1:-}" == "--daemon" ]]; then
  daemonize=1
  shift
fi
LABEL=${1:-auto}

if [[ "$daemonize" -eq 1 ]]; then
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE") status=$(cat "$STATUS" 2>/dev/null || true)"
    exit 0
  fi
  setsid "$0" "$LABEL" </dev/null >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  set_status "waiting-flash label=$LABEL"
  echo "started pid=$! log=$LOG status=$STATUS"
  exit 0
fi

echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

log "observe start label=$LABEL pid=$$"
set_status "waiting-flash label=$LABEL"

# Wait until flash watcher reports ok (or we see ACM appear after a flash attempt)
for i in $(seq 1 900); do
  st=$(cat "$FLASH_STATUS" 2>/dev/null || true)
  if [[ "$st" == ok* ]]; then
    log "flash ok detected: $st"
    break
  fi
  # Also proceed if flash just finished and device left 9008
  if [[ "$st" == flashing* ]]; then
    set_status "flash-in-progress label=$LABEL"
  fi
  sleep 2
  if [[ $i -eq 900 ]]; then
    set_status "TIMEOUT waiting for flash ok"
    log "TIMEOUT waiting for flash"
    exit 1
  fi
done

set_status "observing-boot label=$LABEL"
log "observing boot"
: >"$MARKERS"
outcome=UNKNOWN

for i in $(seq 1 45); do
  usb=$(lsusb 2>/dev/null | grep -iE '9008|d00d|0104' || true)
  acm=
  if lsusb 2>/dev/null | grep -q '1d6b:0104'; then
    modprobe cdc_acm 2>/dev/null || true
    # The ESP32 servo is also a CDC ACM device and is commonly ttyACM0.
    # Resolve the phone by its stable USB identity; never guess an ACM index.
    for candidate in /dev/serial/by-id/*nubia*cerro-debug-if00; do
      if [[ -e "$candidate" ]]; then
        acm=$candidate
        break
      fi
    done
  fi
  log "[$i] usb=[$usb] acm=[$acm -> $(readlink -f "$acm" 2>/dev/null || true)]"
  if [[ -n "$acm" ]]; then
    chmod 666 "$acm" 2>/dev/null || true
    CERRO_ACM="$acm" python3 - <<'PY' >"$MARKERS" 2>/dev/null || true
import os, select, time, re
fd = open(os.environ["CERRO_ACM"], "rb", buffering=0)
deadline = time.time() + 6
buf = b""
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            c = fd.read(4096)
            if c:
                buf += c
        except Exception:
            break
fd.close()
text = buf[-20000:].decode("utf-8", "replace")
open("/tmp/cerro-boot-observe.raw", "w").write(text)
lines = [ln for ln in text.splitlines() if "cerro:" in ln]
print("\n".join(lines[-50:]))
PY
    # classify from markers
    if grep -q 'stop after component_bind_all' "$MARKERS" 2>/dev/null; then
      outcome=PASS_AFTER_BIND_ALL
    elif grep -q 'stop after drm_dev_alloc' "$MARKERS" 2>/dev/null; then
      outcome=PASS_AFTER_DRM_ALLOC
    elif grep -q 'stop after shrinker' "$MARKERS" 2>/dev/null; then
      outcome=PASS_AFTER_SHRINKER
    elif grep -q 'skip component_bind_all' "$MARKERS" 2>/dev/null; then
      outcome=PASS_SKIP_BIND
    elif grep -q 'match NULL' "$MARKERS" 2>/dev/null; then
      outcome=PASS_NULL_MATCH
    elif grep -q 'cerro:' "$MARKERS" 2>/dev/null; then
      outcome=PASS_ACM_MARKERS
    else
      outcome=PASS_ACM
    fi
    break
  fi
  if echo "$usb" | grep -q d00d && [[ $i -ge 12 ]]; then
    outcome=FAIL_STICKY_FB
    break
  fi
  if [[ $i -ge 25 && -z "$usb" ]]; then
    outcome=FAIL_NO_USB
    break
  fi
  sleep 2
done

set_status "done outcome=$outcome label=$LABEL ts=$(date -Iseconds)"
log "OUTCOME=$outcome"
echo "$(date -Iseconds)	${LABEL}	$outcome	auto_observe	$(cat "$FLASH_STATUS" 2>/dev/null | tr '\t' ' ')" >>"$TSV" || true
# Keep process around briefly so status is readable; then exit
exit 0
