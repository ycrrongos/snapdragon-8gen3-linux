#!/usr/bin/env bash
# Install Cerro UCM (Speaker/Earpiece/Mic/VoiceCall) + route helpers + callaudiod.
# Run on phone as root (or via cerro-acm-push + acm-run --sudo).
set -euo pipefail

ROOT="${1:-}"
SRC_UCM="${ROOT}/usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO"
ALT_UCM="${ROOT}/usr/share/alsa/ucm2/conf.d/SM8650-CERRO"
BIN="${ROOT}/usr/local/sbin"

install -d "$SRC_UCM" "$ALT_UCM" "$BIN"

# Expect files next to this script's repo copy when invoked from host push,
# or already staged under /tmp/cerro-audio-voice/.
STAGE="${CERRO_AUDIO_STAGE:-/tmp/cerro-audio-voice}"
for f in HiFi.conf VoiceCall.conf SM8650-CERRO.conf; do
  [[ -f "$STAGE/$f" ]] || { echo "missing $STAGE/$f" >&2; exit 1; }
done

install -m 0644 "$STAGE/HiFi.conf" "$SRC_UCM/HiFi.conf"
install -m 0644 "$STAGE/VoiceCall.conf" "$SRC_UCM/VoiceCall.conf"
install -m 0644 "$STAGE/SM8650-CERRO.conf" "$SRC_UCM/SM8650-CERRO.conf"
install -m 0644 "$STAGE/HiFi.conf" "$ALT_UCM/HiFi.conf"
install -m 0644 "$STAGE/VoiceCall.conf" "$ALT_UCM/VoiceCall.conf" 2>/dev/null || true
install -m 0644 "$STAGE/SM8650-CERRO.conf" "$ALT_UCM/SM8650-CERRO.conf"

install -m 0755 "$STAGE/cerro-audio-route.sh" "$BIN/cerro-audio-route"
install -m 0755 "$STAGE/cerro-voice-bridge.sh" "$BIN/cerro-voice-bridge"
install -m 0755 "$STAGE/cerro-mm-voice-watch.sh" "$BIN/cerro-mm-voice-watch" 2>/dev/null || true
if [[ -f "$STAGE/cerro-audio-bootfix.sh" ]]; then
  install -m 0755 "$STAGE/cerro-audio-bootfix.sh" "$BIN/cerro-audio-bootfix"
fi

# User PATH usually has /usr/local/bin but not sbin
install -d "${ROOT}/usr/local/bin"
for b in cerro-audio-route cerro-voice-bridge cerro-mm-voice-watch cerro-audio-bootfix; do
  [[ -e "$BIN/$b" ]] || continue
  ln -sfn "/usr/local/sbin/$b" "${ROOT}/usr/local/bin/$b"
done
# WP 0.5 ignores main.lua.d; drop obsolete fragment if present
rm -f "${ROOT}/etc/wireplumber/main.lua.d/99-cerro-alsa-ucm.lua"

USER_UNIT_DIR="${ROOT}/etc/systemd/user"
install -d "$USER_UNIT_DIR"
if [[ -f "$STAGE/callaudiod.service" ]]; then
  install -m 0644 "$STAGE/callaudiod.service" "$USER_UNIT_DIR/callaudiod.service"
fi
if [[ -f "$STAGE/cerro-mm-voice-watch.service" ]]; then
  install -m 0644 "$STAGE/cerro-mm-voice-watch.service" "$USER_UNIT_DIR/cerro-mm-voice-watch.service"
fi
if [[ -f "$STAGE/cerro-audio-bootfix.service" ]]; then
  install -m 0644 "$STAGE/cerro-audio-bootfix.service" "$USER_UNIT_DIR/cerro-audio-bootfix.service"
fi

if id rong >/dev/null 2>&1; then
  loginctl enable-linger rong 2>/dev/null || true
  uid=$(id -u rong)
  runtime="/run/user/$uid"
  if [[ -S "$runtime/bus" ]]; then
    sudo -u rong XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      systemctl --user daemon-reload || true
    sudo -u rong XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      systemctl --user enable --now callaudiod.service cerro-mm-voice-watch.service || true
  fi
fi

alsaucm -c SM8650-CERRO reload 2>/dev/null || true
echo "installed UCM + cerro-audio-route + cerro-voice-bridge + callaudiod units"
