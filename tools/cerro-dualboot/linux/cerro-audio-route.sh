#!/usr/bin/env bash
# Switch Cerro playback path like Aurora speaker vs handset.
# Usage: cerro-audio-route speaker|earpiece|status
set -euo pipefail

CARD="${CERRO_ALSA_CARD:-0}"
PW_CARD="${CERRO_PW_CARD:-alsa_card.platform-sound}"
PROFILE_SPEAKER='HiFi (Mic, Speaker)'
PROFILE_EARPIECE='HiFi (Earpiece, Mic)'

amixer_c() { amixer -c "$CARD" "$@"; }

as_user() {
  local uid
  uid=$(id -u rong 2>/dev/null || id -u)
  local runtime="/run/user/$uid"
  if [[ -S "$runtime/bus" ]] && [[ "$(id -u)" -eq 0 ]]; then
    sudo -u "#$uid" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" "$@"
  else
    "$@"
  fi
}

set_pw_profile() {
  local profile=$1
  # voice-bridge sets VoiceCall profile itself; skip when CERRO_SKIP_PW=1
  [[ "${CERRO_SKIP_PW:-0}" == "1" ]] && return 0
  as_user pactl set-card-profile "$PW_CARD" "$profile" 2>/dev/null || true
}

route_speaker() {
  amixer_c -q cset name='PRIMARY_MI2S_RX Audio Mixer MultiMedia1' on,on || true
  amixer_c -q cset name='SpkrLeft Profile Set' Music
  amixer_c -q cset name='SpkrRight Profile Set' Music
  amixer_c -q sset 'SpkrLeft PCM' 270 || amixer_c -q cset name='SpkrLeft PCM Playback Volume' 270
  amixer_c -q sset 'SpkrRight PCM' 270 || amixer_c -q cset name='SpkrRight PCM Playback Volume' 270
  set_pw_profile "$PROFILE_SPEAKER"
  echo "route=speaker (L+R Music + HiFi Speaker)"
}

route_earpiece() {
  amixer_c -q cset name='PRIMARY_MI2S_RX Audio Mixer MultiMedia1' on,on || true
  amixer_c -q cset name='SpkrLeft Profile Set' Receiver
  amixer_c -q cset name='SpkrRight Profile Set' Music
  amixer_c -q sset 'SpkrLeft PCM' 280 || amixer_c -q cset name='SpkrLeft PCM Playback Volume' 280
  amixer_c -q sset 'SpkrRight PCM' 0 || amixer_c -q cset name='SpkrRight PCM Playback Volume' 0
  set_pw_profile "$PROFILE_EARPIECE"
  echo "route=earpiece (Left Receiver, Right muted + HiFi Earpiece)"
}

status() {
  amixer_c sget 'SpkrLeft Profile Set' | sed -n '1,6p'
  amixer_c sget 'SpkrRight Profile Set' | sed -n '1,6p'
  amixer_c sget 'SpkrLeft PCM' | sed -n '1,8p'
  amixer_c sget 'SpkrRight PCM' | sed -n '1,8p'
  as_user pactl list cards 2>/dev/null | sed -n '/Name: alsa_card.platform-sound/,/Active Profile/p' | grep -E 'Active Profile|Profiles:' || true
}

case "${1:-status}" in
  speaker|spk) route_speaker ;;
  earpiece|ear|handset|receiver) route_earpiece ;;
  status) status ;;
  *) echo "usage: $0 speaker|earpiece|status" >&2; exit 2 ;;
esac
