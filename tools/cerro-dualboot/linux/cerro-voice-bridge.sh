#!/usr/bin/env bash
# Switch Cerro between media (Speaker) and in-call (Earpiece) PipeWire/UCM profiles.
# Also toggles AW88261 profiles via cerro-audio-route as a belt-and-suspenders path.
set -euo pipefail

CARD="${CERRO_PW_CARD:-alsa_card.platform-sound}"
ROUTE="${CERRO_AUDIO_ROUTE:-/usr/local/sbin/cerro-audio-route}"
PROFILE_SPEAKER='HiFi (Mic, Speaker)'
PROFILE_EARPIECE='HiFi (Earpiece, Mic)'
PROFILE_VOICE='VoiceCall (Earpiece, Mic)'
PROFILE_VOICE_SPK='VoiceCall (Mic, Speaker)'

as_user() {
  local uid
  uid=$(id -u rong 2>/dev/null || id -u)
  local runtime="/run/user/$uid"
  if [[ -S "$runtime/bus" ]]; then
    sudo -u "#$uid" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" "$@"
  else
    "$@"
  fi
}

set_profile() {
  local profile=$1
  as_user pactl set-card-profile "$CARD" "$profile" 2>/dev/null || true
}

sidetone_on() {
  # Local mic→earpiece loop for call presence; does NOT carry remote/modem PCM.
  as_user pactl unload-module module-loopback 2>/dev/null || true
  as_user pactl load-module module-loopback latency_msec=20     source=alsa_input.platform-sound.VoiceCall__Mic__source     sink=alsa_output.platform-sound.VoiceCall__Earpiece__sink 2>/dev/null     || as_user pactl load-module module-loopback latency_msec=20 2>/dev/null || true
}

sidetone_off() {
  as_user pactl unload-module module-loopback 2>/dev/null || true
}


# Apply AW mixer without letting audio-route clobber the PW profile we want.
aw_route() {
  local mode=$1
  if [[ -x "$ROUTE" ]]; then
    CERRO_SKIP_PW=1 "$ROUTE" "$mode" || "$ROUTE" "$mode" || true
  fi
}

enable_voice() {
  # Mixer first (Receiver + mute right), then force VoiceCall profile last.
  aw_route earpiece
  if as_user pactl list cards 2>/dev/null | grep -q "VoiceCall (Earpiece"; then
    set_profile "$PROFILE_VOICE"
  else
    set_profile "$PROFILE_EARPIECE"
  fi
  if as_user busctl --user call org.mobian_project.CallAudio /org/mobian_project/CallAudio \
      org.mobian_project.CallAudio SelectMode u 1 >/dev/null 2>&1; then
    as_user busctl --user call org.mobian_project.CallAudio /org/mobian_project/CallAudio \
      org.mobian_project.CallAudio EnableSpeaker b false >/dev/null 2>&1 || true
  fi
  sidetone_on
  echo "voice-bridge: on (VoiceCall earpiece + local sidetone)"
}

disable_voice() {
  if as_user busctl --user call org.mobian_project.CallAudio /org/mobian_project/CallAudio \
      org.mobian_project.CallAudio SelectMode u 0 >/dev/null 2>&1; then
    :
  fi
  aw_route speaker
  sidetone_off
  set_profile "$PROFILE_SPEAKER"
  echo "voice-bridge: off (HiFi speaker)"
}

speakerphone_on() {
  aw_route speaker
  if as_user pactl list cards 2>/dev/null | grep -q "VoiceCall (Mic, Speaker)"; then
    set_profile "$PROFILE_VOICE_SPK"
  else
    set_profile "$PROFILE_SPEAKER"
  fi
  as_user busctl --user call org.mobian_project.CallAudio /org/mobian_project/CallAudio \
    org.mobian_project.CallAudio EnableSpeaker b true >/dev/null 2>&1 || true
  echo "voice-bridge: speakerphone on"
}

status() {
  as_user pactl list cards 2>/dev/null | sed -n '/Name: alsa_card.platform-sound/,/Active Profile/p' | tail -20
  [[ -x "$ROUTE" ]] && CERRO_SKIP_PW=1 "$ROUTE" status || true
  as_user busctl --user get-property org.mobian_project.CallAudio /org/mobian_project/CallAudio \
    org.mobian_project.CallAudio AudioMode 2>/dev/null || true
  mmcli -m 0 --voice-list-calls 2>/dev/null || true
}

case "${1:-status}" in
  on|enable|start) enable_voice ;;
  off|disable|stop) disable_voice ;;
  speakerphone|spkphone) speakerphone_on ;;
  status) status ;;
  *) echo "usage: $0 on|off|speakerphone|status" >&2; exit 2 ;;
esac
