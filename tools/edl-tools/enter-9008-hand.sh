#!/usr/bin/env bash
# Enter Qualcomm EDL (05c6:9008) using the agent-phone servo hand.
# Hardware recipe (cerro): hold Power + Vol+ + Vol- until 9008 appears, then release.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOL/../.." && pwd)"
CLI="$ROOT/tools/agent-phone/servo_cli.py"
ANGLES_ENV="$ROOT/tools/agent-phone/press-angles.env"
# Max seconds to keep pressed while waiting for 9008 (not a fixed release timer).
HOLD_S="${HOLD_S:-60}"
MIN_HOLD_S="${MIN_HOLD_S:-8}"
# Optional: reboot phone from ACM while keys are held (Linux→EDL).
REBOOT_ACM="${REBOOT_ACM:-1}"

# Apply calibrated press angles before hold (board does not persist NVS).
if [[ -f "$ANGLES_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$ANGLES_ENV"
  python3 - <<PY
import serial, time
from pathlib import Path
port = str(next(Path("/dev/serial/by-id").glob("*Espressif*")))
ser = serial.Serial(port, 115200, timeout=1.5)
time.sleep(0.3)
ser.reset_input_buffer()
cmds = [
    f"PRESSU:{int('${PRESSU:-59}')}",
    f"PRESSD:{int('${PRESSD:-137}')}",
    f"PRESSP:{int('${PRESSP:-142}')}",
    f"RESTU:{int('${RESTU:-90}')}",
    f"RESTD:{int('${RESTD:-90}')}",
    f"RESTP:{int('${RESTP:-90}')}",
]
for c in cmds:
    ser.write((c + "\n").encode()); ser.flush()
    ser.readline()
ser.close()
print(f"applied angles from press-angles.env: {cmds[0]} {cmds[1]} {cmds[2]}")
PY
fi

have_9008() { lsusb 2>/dev/null | grep -q '05c6:9008'; }

usb_line() {
  lsusb 2>/dev/null | grep -iE '9008|d00d|0104|0112|05c6|18d1|1d6b|19d2|4ee7|4e11' | head -5 || echo '(none)'
}

if have_9008; then
  echo "OK: already 9008"
  lsusb | grep 9008
  exit 0
fi

if [[ ! -f "$CLI" ]]; then
  echo "ERROR: missing $CLI" >&2
  exit 2
fi

echo "enter-9008-hand: hold until 9008 (max ${HOLD_S}s, min ${MIN_HOLD_S}s)  usb=$(usb_line | tr '\n' ' ')"

# If phone is already on Linux ACM, kick a reboot shortly after press starts
# so the held keys catch the reset into EDL.
if [[ "$REBOOT_ACM" == "1" ]]; then
  (
    sleep 2
    PHONE=$(ls /dev/serial/by-id/usb-nubia* 2>/dev/null | head -1 || true)
    [[ -n "$PHONE" ]] || exit 0
    python3 - <<PY || true
import serial, time
port = "$PHONE"
try:
    ser = serial.Serial(port, 115200, timeout=0.2)
except Exception as e:
    print(f"reboot-acm skip: {e}")
    raise SystemExit(0)
ser.write(b"echo CERRO_REBOOT_FOR_EDL >/dev/kmsg\\n")
time.sleep(0.05)
ser.write(b"echo 1 >/proc/sys/kernel/sysrq; echo b >/proc/sysrq-trigger\\n")
time.sleep(0.05)
ser.write(b"reboot -f\\n")
ser.close()
print(f"reboot-acm sent via {port}")
PY
  ) &
  REBOOT_PID=$!
else
  REBOOT_PID=
fi

set +e
python3 "$CLI" hold-edl --seconds "$HOLD_S" --min-hold "$MIN_HOLD_S"
rc=$?
set -e
[[ -n "${REBOOT_PID:-}" ]] && wait "$REBOOT_PID" 2>/dev/null || true

if have_9008; then
  echo "OK: 9008"
  lsusb | grep 9008
  exit 0
fi

echo "TIMEOUT/FAIL: no 9008 after until-release hold. usb=$(usb_line | tr '\n' ' ')" >&2
exit "${rc:-1}"
