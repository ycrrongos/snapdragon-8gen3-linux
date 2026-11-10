#!/bin/sh
# PipeWire/WirePlumber must not probe ACP before SM8650-CERRO exists.
# Early user@UID (linger / getty) otherwise freezes Active Profile=off.
i=0
while [ "$i" -lt 240 ]; do
  if grep -q SM8650CERRO /proc/asound/cards 2>/dev/null; then
    exit 0
  fi
  sleep 0.5
  i=$((i + 1))
done
echo "cerro-wait-alsa-card: timeout waiting for SM8650CERRO" >&2
exit 0
