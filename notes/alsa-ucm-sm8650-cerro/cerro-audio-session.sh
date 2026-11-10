#!/bin/sh
# After PipeWire/WirePlumber: select Cerro UCM speaker profile and default sink.
# ACP profile titles are "HiFi (Mic, Speaker)", not bare "HiFi".

log() { echo "cerro-audio-session: $*" >&2; }

PROFILE_SPEAKER='HiFi (Mic, Speaker)'
err="${XDG_RUNTIME_DIR:-/tmp}/cerro-pactl-load.err"

i=0
while [ "$i" -lt 90 ]; do
  grep -q SM8650CERRO /proc/asound/cards 2>/dev/null && break
  sleep 1
  i=$((i + 1))
done
grep -q SM8650CERRO /proc/asound/cards 2>/dev/null || {
  log "no ALSA card"
  exit 0
}

command -v pactl >/dev/null 2>&1 || {
  log "no pactl"
  exit 0
}

i=0
while [ "$i" -lt 45 ]; do
  pactl info >/dev/null 2>&1 && break
  sleep 1
  i=$((i + 1))
done

# Wait until WirePlumber has published the UCM verb (not just the card node).
i=0
while [ "$i" -lt 40 ]; do
  pactl list cards 2>/dev/null | grep -q "$PROFILE_SPEAKER" && break
  sleep 0.5
  i=$((i + 1))
done

idx=$(pactl list short cards 2>/dev/null | awk '/platform-sound/{print $1; exit}')
sn=""

# Drop legacy fallback module so UCM owns hw:0.
pactl list short modules 2>/dev/null | while IFS="$(printf '\t')" read -r mid mname margs; do
  [ "$mname" = module-alsa-sink ] || continue
  case "$margs" in
    *sink_name=cerro_speaker*) pactl unload-module "$mid" >/dev/null 2>&1 || true ;;
  esac
done

if [ -n "$idx" ]; then
  cur=$(pactl list cards 2>/dev/null | awk '/Name: alsa_card.platform-sound/{p=1} p&&/Active Profile:/{print; exit}')
  case "$cur" in
    *"$PROFILE_SPEAKER"*) ;;
    *) pactl set-card-profile "$idx" "$PROFILE_SPEAKER" >/dev/null 2>&1 || true ;;
  esac
fi

i=0
while [ "$i" -lt 15 ]; do
  sn=$(pactl list short sinks 2>/dev/null | awk '
    /platform-sound/ && /Speaker|Loudspeaker|HiFi/ { print $2; exit }
    /alsa_output\.platform-sound\.HiFi/ { print $2; exit }
  ')
  [ -n "$sn" ] && break
  sleep 0.5
  i=$((i + 1))
done

if [ -z "$sn" ]; then
  log "warn: no UCM speaker sink yet; ALSA module fallback"
  amixer -c0 cset name='PRIMARY_MI2S_RX Audio Mixer MultiMedia1' on,on >/dev/null 2>&1 || \
    amixer -c0 cset name='PRIMARY_MI2S_RX Audio Mixer MultiMedia1' 1,1 >/dev/null 2>&1 || true
  if ! pactl list short sinks 2>/dev/null | grep -q '[[:space:]]cerro_speaker[[:space:]]'; then
    pactl load-module module-alsa-sink \
      device=plughw:0,0 \
      sink_name=cerro_speaker \
      sink_properties=device.description=Cerro_Speakers \
      rate=48000 format=s16le channels=2 >"$err" 2>&1 || \
    pactl load-module module-alsa-sink \
      device=hw:0,0 \
      sink_name=cerro_speaker \
      sink_properties=device.description=Cerro_Speakers \
      rate=48000 format=s16le channels=2 >"$err" 2>&1 || true
  fi
  sn=$(pactl list short sinks 2>/dev/null | awk '/[[:space:]]cerro_speaker[[:space:]]/{print $2; exit}')
fi

if [ -n "$sn" ]; then
  pactl set-default-sink "$sn" >/dev/null 2>&1 || true
  pactl set-sink-mute "$sn" 0 >/dev/null 2>&1 || true
  pactl set-sink-volume "$sn" 80% >/dev/null 2>&1 || true
  log "default sink=$sn"
else
  log "warn: no usable sink"
fi
exit 0
