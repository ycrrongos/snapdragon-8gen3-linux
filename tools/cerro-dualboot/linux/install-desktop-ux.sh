#!/bin/bash
# Install login-screen + power-key v2 + Switch-to-Android on live Debian.
# Run as root on the phone (or via ACM sudo).
#
# HARD RULES (2026-10-15/16 crash lessons — do not regress):
# 1) Do NOT set DisplayServer=wayland for greeter (needs weston; missing → X11 fallback mess).
# 2) Do NOT install/build cerro-dpms; powerkey must use PowerDevil only.
# 3) Do NOT write kwinoutputconfig.json brightness / sysfs panel brightness.
# 4) Autolock=false so blank screen wakes by touch (double-tap), not lock screen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "=== 1) SDDM: show login screen (no DisplayServer=wayland) ==="
mkdir -p /etc/sddm.conf.d
cat >/etc/sddm.conf.d/cerro.conf <<'EOF'
[Autologin]
User=
Session=
Relogin=false
EOF
# Clear autologin in kde_settings if present; keep theme only
if [[ -f /etc/sddm.conf.d/kde_settings.conf ]]; then
  cat >/etc/sddm.conf.d/kde_settings.conf <<'EOF'
[Autologin]
Relogin=false
Session=
User=

[Theme]
Current=breeze

[Users]
MaximumUid=60000
MinimumUid=1000
EOF
fi
# Strip any DisplayServer=wayland left from older configs
sed -i '/^DisplayServer=/d' /etc/sddm.conf.d/*.conf 2>/dev/null || true
sed -i '/^\[General\]$/d' /etc/sddm.conf.d/cerro.conf 2>/dev/null || true

echo "=== 2) Unbind Power key from PowerDevil (handler owns it) ==="
USER_HOME=/home/rong
KS="$USER_HOME/.config/kglobalshortcutsrc"
if [[ -f "$KS" ]]; then
  python3 - <<'PY'
from pathlib import Path
p = Path("/home/rong/.config/kglobalshortcutsrc")
text = p.read_text()
lines = []
in_pd = False
for line in text.splitlines():
    if line.strip() == "[org_kde_powerdevil]":
        in_pd = True
        lines.append(line)
        continue
    if in_pd and line.startswith("["):
        in_pd = False
    if in_pd and line.startswith("PowerDown="):
        lines.append("PowerDown=none,none,Power Down")
        continue
    if in_pd and line.startswith("PowerOff="):
        lines.append("PowerOff=none,none,Power Off")
        continue
    lines.append(line)
p.write_text("\n".join(lines) + ("\n" if text.endswith("\n") else ""))
print("patched", p)
PY
  chown rong:rong "$KS"
fi

echo "=== 3) powerkey v2 (PowerDevil only) + no-autolock ==="
# Explicitly remove dpms helper if someone left it around
rm -f /usr/local/sbin/cerro-dpms
install -m755 "$ROOT/cerro-powerkey.py" /usr/local/sbin/cerro-powerkey.py
install -m644 "$ROOT/cerro-powerkey.service" /etc/systemd/system/cerro-powerkey.service
# Real unit file (not a mask to /dev/null)
if [[ -L /etc/systemd/system/cerro-powerkey.service ]]; then
  rm -f /etc/systemd/system/cerro-powerkey.service
  install -m644 "$ROOT/cerro-powerkey.service" /etc/systemd/system/cerro-powerkey.service
fi
install -o rong -g rong -m644 "$ROOT/cerro-kscreenlockerrc" /home/rong/.config/kscreenlockerrc
# No idle suspend (keep USB ACM / bring-up expectation).
# Also disable critical-battery shutdown: at ~2% UPower often reports
# warning-level=action + state=discharging even while sysfs says Charging
# (charge_full empty / current_now sign flaky), and Plasma default
# BatteryCriticalAction=Shutdown kills the session ~20s after login.
cat >/home/rong/.config/powerdevilrc <<'EOF'
[AC][SuspendSession]
idleTime=0
suspendType=0

[Battery][SuspendSession]
idleTime=0
suspendType=0

[LowBattery][SuspendSession]
idleTime=0
suspendType=0

[BatteryManagement]
BatteryLowLevel=5
BatteryCriticalLevel=1
BatteryCriticalAction=0
EOF
chown rong:rong /home/rong/.config/powerdevilrc
install -d /etc/xdg
cp /home/rong/.config/powerdevilrc /etc/xdg/powerdevilrc

if ! python3 -c "import libevdev" 2>/dev/null; then
  apt-get install -y python3-libevdev 2>/dev/null || true
fi

systemctl daemon-reload
systemctl unmask cerro-powerkey.service 2>/dev/null || true
systemctl enable --now cerro-powerkey.service
systemctl restart cerro-powerkey.service

echo "=== 4) Switch-to-Android desktop entry ==="
install -m755 "$ROOT/cerro-switch-to-android.sh" /usr/local/bin/cerro-switch-to-android
install -m644 "$ROOT/cerro-switch-to-android.desktop" /usr/share/applications/cerro-switch-to-android.desktop
install -m644 "$ROOT/org.cerro.switch-to-android.policy" /usr/share/polkit-1/actions/org.cerro.switch-to-android.policy
mkdir -p /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/40-cerro-switch-android.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.cerro.switch-to-android" &&
        subject.user == "rong") {
        return polkit.Result.YES;
    }
});
EOF
cat >/etc/polkit-1/rules.d/41-cerro-switch-android-exec.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/local/bin/cerro-switch-to-android" &&
        subject.user == "rong") {
        return polkit.Result.YES;
    }
});
EOF
update-desktop-database /usr/share/applications 2>/dev/null || true
command -v zenity >/dev/null || apt-get install -y zenity 2>/dev/null || true

echo "=== 5) Done (do NOT touch kwin brightness / cerro-dpms) ==="
systemctl is-active cerro-powerkey.service || true
grep -E '^(User|Session|DisplayServer)=' /etc/sddm.conf.d/*.conf 2>/dev/null || true
ls -la /usr/local/sbin/cerro-powerkey.py
test ! -e /usr/local/sbin/cerro-dpms && echo "cerro-dpms: absent (good)"
echo "OK: greeter on next login; short power=PowerDevil blank/wake; long≥3s=menu."
echo "NOTE: restart sddm to show login now, or reboot once."
