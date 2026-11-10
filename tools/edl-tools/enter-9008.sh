#!/usr/bin/env bash
# Enter Qualcomm EDL (05c6:9008) on cerro from whatever USB state we have.
#
# Strategies (in order):
#   0. Servo hand (prefer): Power+Vol± hold ~12s → tools/edl-tools/enter-9008-hand.sh
#      Skip with NO_HAND=1 if the hand is unplugged / being calibrated.
#   1. Already 9008 → success
#   2. Fastboot → fastboot oem edl / reboot-edl
#   3. ACM (1d6b:0104) → send "edl" to device init → reboot -f → sticky
#      fastboot → oem edl. Fallback: "edl-force" (dload+crash; may be MemoryDump)
#   4. Timeout → print manual Vol± instructions
#
# Requires device init that listens on ttyGS0 (tools/cerro-init/init) for ACM path.
# Usage:
#   enter-9008.sh              # wait up to ~120s
#   enter-9008.sh --timeout 60
#   NO_HAND=1 enter-9008.sh    # skip servo
set -euo pipefail

TIMEOUT=120
NO_HAND=${NO_HAND:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout|-t) TIMEOUT=${2:?}; shift 2 ;;
    --no-hand) NO_HAND=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"

have_9008() { lsusb 2>/dev/null | grep -q '05c6:9008'; }
have_dump() { lsusb 2>/dev/null | grep -q '19d2:0112'; }
have_fb() {
  lsusb 2>/dev/null | grep -q '18d1:d00d' &&
    fastboot devices 2>/dev/null | grep -q fastboot
}
have_acm() { lsusb 2>/dev/null | grep -qi '1d6b:0104'; }

usb_line() {
  lsusb 2>/dev/null | grep -iE '9008|d00d|0104|0112|05c6|18d1|1d6b|19d2' | head -5 || echo '(none)'
}

wait_for() {
  # wait_for <seconds> <predicate-fn-name>
  local secs=$1 pred=$2 i
  for i in $(seq 1 "$secs"); do
    if "$pred"; then return 0; fi
    if have_dump; then
      echo "WARN: ZTE MemoryDump (19d2:0112) — not 9008; force power-off + Vol±" >&2
      return 2
    fi
    sleep 1
  done
  return 1
}

fastboot_to_edl() {
  echo "==== fastboot → oem edl ===="
  fastboot set_active a 2>/dev/null || true
  fastboot oem edl 2>/dev/null || fastboot reboot-edl 2>/dev/null || {
    echo "WARN: oem edl / reboot-edl failed" >&2
    return 1
  }
  if wait_for 40 have_9008; then
    echo "OK: 9008 after fastboot oem edl"
    lsusb | grep 9008
    return 0
  fi
  return 1
}

acm_send_line() {
  local line=$1
  local dev=${ACM_DEV:-/dev/ttyACM0}
  modprobe cdc_acm 2>/dev/null || true
  if [ ! -c "$dev" ]; then
    # wait briefly for ACM node
    local i
    for i in $(seq 1 15); do
      [ -c "$dev" ] && break
      sleep 0.5
    done
  fi
  [ -c "$dev" ] || { echo "ERROR: no $dev" >&2; return 1; }
  echo "==== ACM: send '$line' → $dev ===="
  python3 - "$dev" "$line" <<'PY'
import sys, time, termios, tty
dev, line = sys.argv[1], sys.argv[2]
# Exclusive-ish open; leave DTR/RTS asserted so gadget stays up.
fd = open(dev, "rb+", buffering=0)
try:
    attrs = termios.tcgetattr(fd.fileno())
    attrs[4] = attrs[5] = termios.B115200  # ispeed/ospeed
    # raw-ish
    attrs[3] = attrs[3] & ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(fd.fileno(), termios.TCSANOW, attrs)
except Exception as e:
    print(f"WARN: tcsetattr: {e}", file=sys.stderr)
# Wake any pending read; send command twice for reliability.
payload = (line.strip() + "\n").encode()
for _ in range(2):
    fd.write(b"\n")
    fd.flush()
    time.sleep(0.3)
    fd.write(payload)
    fd.flush()
    time.sleep(0.4)
# Drain a little so we don't leave stale prompt noise for next reader
deadline = time.time() + 2.0
while time.time() < deadline:
    try:
        import select
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        chunk = fd.read(4096)
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    except Exception:
        break
fd.close()
print(f"sent {line!r}")
PY
}

acm_to_edl() {
  echo "==== ACM → edl (reboot -f → fastboot oem edl) ===="
  acm_send_line "edl" || return 1
  # Device drops ACM; wait for fastboot or 9008
  local i
  for i in $(seq 1 50); do
    if have_9008; then
      echo "OK: 9008 directly after ACM edl"
      lsusb | grep 9008
      return 0
    fi
    if have_fb; then
      fastboot_to_edl && return 0
    fi
    if have_dump; then
      echo "WARN: MemoryDump after edl — try force power-off + Vol±" >&2
      return 2
    fi
    (( i % 5 == 0 )) && echo "[$i] waiting after ACM edl: $(usb_line | tr '\n' ';')"
    sleep 1
  done

  echo "==== ACM fallback: edl-force (dload+crash) ===="
  # May have rebooted back to ACM
  if have_acm; then
    acm_send_line "edl-force" || true
    for i in $(seq 1 40); do
      if have_9008; then
        echo "OK: 9008 after edl-force"
        lsusb | grep 9008
        return 0
      fi
      if have_fb; then
        fastboot_to_edl && return 0
      fi
      if have_dump; then
        echo "WARN: MemoryDump after edl-force — force power-off + Vol±" >&2
        return 2
      fi
      sleep 1
    done
  fi
  return 1
}

echo "enter-9008: timeout=${TIMEOUT}s  usb=$(usb_line | tr '\n' ' ')"

if have_9008; then
  echo "OK: already 9008"
  lsusb | grep 9008
  exit 0
fi

if [[ "$NO_HAND" != "1" ]] && [[ -x "$TOOL_DIR/enter-9008-hand.sh" ]]; then
  if ls /dev/serial/by-id 2>/dev/null | grep -qiE 'espressif|usb_jtag'; then
    echo "==== prefer servo hand (Power+Vol± ${HOLD_S:-12}s) ===="
    if HOLD_S="${HOLD_S:-12}" WAIT_S=40 "$TOOL_DIR/enter-9008-hand.sh"; then
      exit 0
    fi
    echo "WARN: hand path failed; falling back to soft methods" >&2
  fi
fi

if have_fb; then
  fastboot_to_edl && exit 0
fi

if have_acm; then
  acm_to_edl && exit 0
fi

echo "No ACM/fastboot/9008 yet — polling ${TIMEOUT}s..."
DEADLINE=$((SECONDS + TIMEOUT))
while (( SECONDS < DEADLINE )); do
  if have_9008; then
    echo "OK: 9008 appeared"
    lsusb | grep 9008
    exit 0
  fi
  if have_fb; then
    fastboot_to_edl && exit 0
  fi
  if have_acm; then
    acm_to_edl && exit 0
  fi
  if have_dump; then
    echo "ERROR: MemoryDump (19d2:0112). Force power-off, hold Vol+ and Vol-, plug USB." >&2
    exit 3
  fi
  sleep 2
done

cat >&2 <<'EOF'
TIMEOUT: could not enter 9008.

Manual:
  1. Long-press power 20–30s (screen black)
  2. Hold Vol+ AND Vol-, plug USB
  3. lsusb → 05c6:9008

Note: ACM "edl" needs tools/cerro-init/init listener baked into Image
(INITRAMFS). Rebuild/flash once after updating initramfs.
EOF
exit 1
