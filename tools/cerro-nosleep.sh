#!/usr/bin/env bash
# Prevent KDE/systemd idle sleep from killing USB gadget / ACM during bring-up.
# Run ON the phone (root), or via: tools/cerro-nosleep.sh --via-serial
set -euo pipefail

MODE="${1:-local}"

apply_local() {
  if [[ "$(id -u)" != 0 ]]; then
    echo "cerro-nosleep: run as root" >&2
    exit 1
  fi
  echo "cerro-nosleep: masking all sleep targets persistently"
  systemctl mask sleep.target suspend.target hibernate.target \
    hybrid-sleep.target suspend-then-hibernate.target

  # UPower CriticalPowerAction=HybridSleep falls back to PowerOff when those
  # sleep targets are masked. At PercentageAction=2 (default) + CAP≈2% this
  # orderly-powers-off the phone ~1–2min after boot — looks like ACM "cable
  # unplug" but boot id changed. Disable the action threshold.
  if [[ -f /etc/UPower/UPower.conf ]]; then
    cp -a /etc/UPower/UPower.conf /etc/UPower/UPower.conf.bak.cerro 2>/dev/null || true
    sed -i \
      -e 's/^PercentageLow=.*/PercentageLow=5.0/' \
      -e 's/^PercentageCritical=.*/PercentageCritical=1.0/' \
      -e 's/^PercentageAction=.*/PercentageAction=0.0/' \
      /etc/UPower/UPower.conf
    systemctl try-restart upower.service 2>/dev/null || true
    echo "cerro-nosleep: UPower PercentageAction=0.0 (no critical poweroff)"
  fi

  cat >/etc/systemd/system/cerro-nosleep.service <<'UNITEOF'
[Unit]
Description=Cerro bring-up: block KDE/system sleep and keep USB ACM alive
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit --what=idle:sleep --who=cerro-bringup --why=keep-USB-ACM-and-install-jobs-alive --mode=block /bin/sleep infinity
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable --now cerro-nosleep.service

  # Plasma 6 PowerDevil: disable automatic suspend for every power profile.
  if [[ -x /usr/bin/kwriteconfig6 && -d /home/user ]]; then
    for profile in AC Battery LowBattery; do
      sudo -n -u user env HOME=/home/user \
        kwriteconfig6 --file powerdevilrc \
          --group "$profile" --group SuspendSession --key idleTime 0
      sudo -n -u user env HOME=/home/user \
        kwriteconfig6 --file powerdevilrc \
          --group "$profile" --group SuspendSession --key suspendType 0
    done
    sudo -n -u user env \
      HOME=/home/user XDG_RUNTIME_DIR=/run/user/10000 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10000/bus \
      systemctl --user try-restart plasma-powerdevil.service 2>/dev/null || true
  fi
  # Plasma / X blanking (ignore failures if not in graphical session)
  if command -v xset >/dev/null && [[ -n "${DISPLAY:-}" ]]; then
    xset s off -dpms || true
  fi
  # Kernel: prefer not suspending USB
  for control in /sys/bus/usb/devices/*/power/control; do
    [[ -e "$control" ]] && echo on >"$control" || true
  done
  echo "cerro-nosleep: done (persistent masks + service inhibitor + PowerDevil)"
}

via_serial() {
  python3 - <<'PY'
import serial, time, glob
ports = [p for p in glob.glob("/dev/serial/by-id/*cerro-debug*") if "Espressif" not in p]
if not ports:
    raise SystemExit("no phone ACM")
ser = serial.Serial(ports[0], 115200, timeout=0.5)
ser.reset_input_buffer()
ser.write(b"\r\n"); time.sleep(0.5); ser.read(4096)
# login if needed
buf = b""
ser.write(b"user\r\n"); time.sleep(1); buf += ser.read(8192)
if b"Password:" in buf or b"password:" in buf:
    ser.write(b"user\r\n"); time.sleep(1.5); buf += ser.read(8192)
cmd = (
    b"echo user | sudo -S sh -c '"
    b"systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; "
    b"pkill -f cerro-nosleep-inhibit || true; "
    b"systemd-inhibit --what=idle:sleep --who=cerro --why=bringup --mode=block sleep infinity >/tmp/cerro-nosleep-inhibit.log 2>&1 & "
    b"echo $! >/tmp/cerro-nosleep-inhibit.pid; "
    b"echo NOSLEEP_OK'"
    b"\r\n"
)
ser.write(cmd)
t0 = time.time(); out = b""
while time.time() - t0 < 20:
    c = ser.read(4096)
    if c:
        out += c
        if b"NOSLEEP_OK" in out:
            break
print(out.decode("utf-8", "replace")[-1500:])
ser.close()
if b"NOSLEEP_OK" not in out:
    raise SystemExit("failed to apply nosleep via serial")
PY
}

case "$MODE" in
  local|--local) apply_local ;;
  --via-serial) via_serial ;;
  *) echo "usage: $0 [--via-serial|local]"; exit 2 ;;
esac
