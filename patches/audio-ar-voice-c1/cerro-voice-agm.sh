#!/bin/bash
# PROBE ONLY — do not hook from Dialer/mm-voice-watch.
# Disconnecting MultiMedia1 + pactl suspend left HiFi stuck after hangup (2026-10-22).
# Remote PCM research continues separately; media path must stay on MultiMedia1.
#
# Usage (manual probe on a spare session after soft reboot if needed):
#   cerro-voice-agm.sh start [hold] [proxy|fluence]
#   cerro-voice-agm.sh stop
set -euo pipefail
BIN=/usr/local/sbin/cerro-vcall-rxtx
PIDF=/run/cerro-voice-agm.pid
LOG=/tmp/cerro-voice-agm.log
export LD_LIBRARY_PATH=/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

echo "WARN: cerro-voice-agm is probe-only; Dialer path must not call this." >&2

ensure_passthru() {
  [[ -e /dev/aud_pasthru_adsp ]] && return 0
  modprobe cerro-audio-shmem 2>/dev/null || \
    insmod /lib/modules/$(uname -r)/extra/cerro-audio-shmem.ko 2>/dev/null || true
  modprobe cerro-aud-pasthru 2>/dev/null || \
    insmod /lib/modules/$(uname -r)/extra/cerro-aud-pasthru.ko 2>/dev/null || true
  [[ -e /dev/aud_pasthru_adsp ]]
}

# Always leave media mixers usable (never leave MultiMedia1 half-off).
restore_media() {
  amixer -c 0 cset name='PRIMARY_MI2S_RX Audio Mixer MultiMedia1' on,on >/dev/null 2>&1 || true
  amixer -c 0 cset name='SpkrLeft Profile Set' Music >/dev/null 2>&1 || true
  amixer -c 0 cset name='SpkrRight Profile Set' Music >/dev/null 2>&1 || true
  sudo -u rong XDG_RUNTIME_DIR=/run/user/1000 \
    pactl suspend-sink @DEFAULT_SINK@ 0 2>/dev/null || true
  sudo -u rong XDG_RUNTIME_DIR=/run/user/1000 \
    pactl suspend-source @DEFAULT_SOURCE@ 0 2>/dev/null || true
  sudo -u rong XDG_RUNTIME_DIR=/run/user/1000 \
    pactl set-card-profile alsa_card.platform-sound 'HiFi (Mic, Speaker)' 2>/dev/null || true
}

cmd=${1:-}
case "$cmd" in
  start)
    echo "refusing auto start that breaks media; use laboratory steps in README" >&2
    exit 3
    ;;
  stop)
    if [ -f "$PIDF" ]; then
      kill "$(cat "$PIDF")" 2>/dev/null || true
      rm -f "$PIDF"
    fi
    pkill -9 -f cerro-vcall-rxtx 2>/dev/null || true
    restore_media
    echo "AGM probe stop + media mixers restored"
    ;;
  restore-media)
    restore_media
    echo "media mixers restored"
    ;;
  *)
    echo "usage: $0 stop|restore-media  (start disabled — probe-only)" >&2
    exit 2
    ;;
esac
