#!/usr/bin/env bash
# After reboot, WirePlumber often probes SM8650-CERRO before ADSP is up and
# ends with Active Profile=off / Dummy Output. Wait for ADSP + PCM, then kick PW.
set -euo pipefail

uid=$(id -u)
runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export XDG_RUNTIME_DIR="$runtime"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime/bus}"

wait_adsp() {
  local i
  for i in $(seq 1 60); do
    for r in /sys/class/remoteproc/remoteproc*; do
      [[ -f "$r/name" ]] || continue
      if [[ "$(cat "$r/name" 2>/dev/null)" == "adsp" ]] && [[ "$(cat "$r/state" 2>/dev/null)" == "running" ]]; then
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

wait_pcm() {
  local i
  for i in $(seq 1 30); do
    [[ -e /proc/asound/card0/pcm0p/info ]] && return 0
    sleep 1
  done
  return 1
}

profile_ok() {
  pactl list cards 2>/dev/null | grep -q 'Active Profile: HiFi\|Active Profile: VoiceCall'
}

wait_adsp || true
wait_pcm || true
sleep 2

if profile_ok; then
  echo "cerro-audio-bootfix: profile already OK"
  exit 0
fi

systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service || true
sleep 3

if ! profile_ok; then
  pactl set-card-profile alsa_card.platform-sound 'HiFi (Mic, Speaker)' 2>/dev/null || true
  /usr/local/sbin/cerro-audio-route speaker 2>/dev/null || true
fi

if profile_ok; then
  echo "cerro-audio-bootfix: restored HiFi Speaker"
  exit 0
fi
echo "cerro-audio-bootfix: still not OK" >&2
exit 1
