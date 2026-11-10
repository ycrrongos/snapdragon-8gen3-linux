#!/usr/bin/env bash
# Watch ModemManager Voice calls and toggle cerro-voice-bridge.
# Install as user service: cerro-mm-voice-watch.service
set -euo pipefail
BRIDGE="${CERRO_VOICE_BRIDGE:-/usr/local/sbin/cerro-voice-bridge}"
STATE=off

apply() {
  local want=$1
  if [[ "$want" == "$STATE" ]]; then
    return 0
  fi
  if [[ "$want" == on ]]; then
    "$BRIDGE" on || true
  else
    "$BRIDGE" off || true
  fi
  STATE=$want
}

# Initial
if mmcli -m 0 --voice-list-calls 2>/dev/null | grep -q '/Call/'; then
  apply on
else
  apply off
fi

# Poll — MM D-Bus CallAdded is nicer but polling is robust without extra deps
while true; do
  if mmcli -m 0 --voice-list-calls 2>/dev/null | grep -q '/Call/'; then
    apply on
  else
    apply off
  fi
  sleep 2
done
