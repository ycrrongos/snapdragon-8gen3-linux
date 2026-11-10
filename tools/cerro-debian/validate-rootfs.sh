#!/bin/sh
# Pre-boot validation for the complete native Debian Cerro root.
set -u

DEBIAN_ROOT=${1:-/debian-root}
KERNEL_RELEASE=$(uname -r)
FAILURES=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
check_path() {
  if [ -e "$DEBIAN_ROOT$1" ]; then pass "$1"; else fail "$1 missing"; fi
}
check_exec() {
  if [ -x "$DEBIAN_ROOT$1" ]; then pass "$1"; else fail "$1 not executable"; fi
}
check_enabled() {
  if chroot "$DEBIAN_ROOT" systemctl is-enabled "$1" >/dev/null 2>&1; then
    pass "$1 enabled"
  else
    fail "$1 not enabled"
  fi
}

if [ "$(id -u)" != 0 ]; then
  echo "validate-rootfs: run as root" >&2
  exit 2
fi

grep -q '^ID=debian$' "$DEBIAN_ROOT/etc/os-release" 2>/dev/null \
  && pass "Debian os-release" || fail "not Debian"
grep -q '^VERSION_ID="\?13"\?$' "$DEBIAN_ROOT/etc/os-release" 2>/dev/null \
  && pass "Debian 13" || fail "not Debian 13"
[ "$(chroot "$DEBIAN_ROOT" dpkg --print-architecture 2>/dev/null)" = arm64 ] \
  && pass "arm64 architecture" || fail "not arm64"

for REQUIRED_EXEC in \
  /sbin/init /lib/systemd/systemd /bin/bash /usr/bin/kwin_wayland \
  /usr/bin/plasmashell /usr/bin/firefox-esr /usr/sbin/NetworkManager \
  /usr/libexec/bluetooth/bluetoothd /cerro-sd-prep; do
  check_exec "$REQUIRED_EXEC"
done
for REQUIRED_PATH in \
  /.cerro-native-debian \
  "/lib/modules/$KERNEL_RELEASE" \
  /lib/firmware/ath12k /lib/firmware/qca \
  /lib/firmware/qcom/sm8650/SM8650-CERRO-tplg.bin \
  /lib/firmware/aw882xx_acf.bin \
  /usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO/SM8650-CERRO.conf \
  /usr/local/sbin/cerro-audio-up.sh \
  /usr/local/sbin/cerro-wifi-up.sh \
  /usr/local/sbin/cerro-bt-up.sh \
  /usr/local/sbin/cerro-usb-acm.sh \
  /usr/bin/qbootctl \
  /usr/lib/aarch64-linux-gnu/dri/msm_dri.so \
  /usr/share/wayland-sessions/plasma.desktop \
  /home/user/.config/powerdevilrc; do
  check_path "$REQUIRED_PATH"
done

chroot "$DEBIAN_ROOT" id user >/dev/null 2>&1 \
  && pass "user account" || fail "user account"
for REQUIRED_UNIT in \
  NetworkManager.service bluetooth.service sddm.service \
  serial-getty@ttyGS0.service cerro-nosleep.service \
  cerro-usb-acm.service cerro-usbnet.service cerro-wifi.service \
  cerro-bt.service cerro-audio.service qbootctl.service; do
  check_enabled "$REQUIRED_UNIT"
done
for MASKED_UNIT in \
  sleep.target suspend.target hibernate.target hybrid-sleep.target \
  suspend-then-hibernate.target; do
  if [ "$(chroot "$DEBIAN_ROOT" systemctl is-enabled "$MASKED_UNIT" 2>/dev/null)" = masked ]; then
    pass "$MASKED_UNIT masked"
  else
    fail "$MASKED_UNIT not masked"
  fi
done

if [ -z "$(chroot "$DEBIAN_ROOT" dpkg --audit 2>/dev/null)" ]; then
  pass "dpkg audit clean"
else
  fail "dpkg audit reports unfinished packages"
fi
chroot "$DEBIAN_ROOT" apt-get check >/dev/null 2>&1 \
  && pass "APT dependency check" || fail "APT dependency check"
if chroot "$DEBIAN_ROOT" /usr/bin/qbootctl -h 2>&1 | grep -qi 'qbootctl'; then
  pass "native Debian qbootctl executes"
else
  fail "qbootctl cannot execute natively"
fi

SOURCE_TOPOLOGY=$(sha256sum /lib/firmware/qcom/sm8650/SM8650-CERRO-tplg.bin 2>/dev/null | awk '{print $1}')
DEBIAN_TOPOLOGY=$(sha256sum "$DEBIAN_ROOT/lib/firmware/qcom/sm8650/SM8650-CERRO-tplg.bin" 2>/dev/null | awk '{print $1}')
[ -n "$SOURCE_TOPOLOGY" ] && [ "$SOURCE_TOPOLOGY" = "$DEBIAN_TOPOLOGY" ] \
  && pass "s5fz topology SHA256 $DEBIAN_TOPOLOGY" \
  || fail "s5fz topology hash mismatch"

PROFILE_COUNT=$(find "$DEBIAN_ROOT/etc/NetworkManager/system-connections" \
  -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$PROFILE_COUNT" -gt 0 ] \
  && pass "NetworkManager profiles: $PROFILE_COUNT" \
  || fail "no NetworkManager profile"

du -shx "$DEBIAN_ROOT"
if [ "$FAILURES" -ne 0 ]; then
  echo "validate-rootfs: $FAILURES failure(s)"
  exit 1
fi
echo "validate-rootfs: all native Debian pre-boot checks passed"
