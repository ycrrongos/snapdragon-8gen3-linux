#!/usr/bin/env bash
# After a bisect PASS (ACM up + optional log marker), enter 9008 for the next flash.
#
# Usage:
#   pass-then-9008.sh [marker-regex]
# Env:
#   ACM_DEV=/dev/ttyACM0
#   PASS_WAIT=90          # seconds to wait for ACM/marker
#   LOG=...               # optional tee path
set -euo pipefail
MARKER=${1:-'cerro: dpu |CERRO USB|cerro-usb'}
PASS_WAIT=${PASS_WAIT:-90}
ENTER=$(dirname "$(readlink -f "$0")")/enter-9008.sh
LOG=${LOG:-}

echo "Waiting up to ${PASS_WAIT}s for ACM (+ optional marker)..."
deadline=$((SECONDS + PASS_WAIT))
while (( SECONDS < deadline )); do
  if lsusb 2>/dev/null | grep -qi '1d6b:0104'; then
    modprobe cdc_acm 2>/dev/null || true
    sleep 2
    if [ -n "$MARKER" ] && [ -c "${ACM_DEV:-/dev/ttyACM0}" ]; then
      tmp=$(mktemp)
      timeout 12 cat "${ACM_DEV:-/dev/ttyACM0}" >"$tmp" 2>/dev/null || true
      if [ -n "${LOG:-}" ]; then cat "$tmp" >>"$LOG"; fi
      if rg -q "$MARKER" "$tmp"; then
        echo "PASS marker seen — entering 9008"
        rm -f "$tmp"
        exec "$ENTER" --timeout 120
      fi
      echo "ACM up but marker not in sample; still trying enter-9008"
      rm -f "$tmp"
    else
      echo "ACM up — entering 9008"
    fi
    exec "$ENTER" --timeout 120
  fi
  if lsusb 2>/dev/null | grep -qE '05c6:9008|18d1:d00d'; then
    exec "$ENTER" --timeout 60
  fi
  sleep 2
done
echo "TIMEOUT waiting for PASS/ACM" >&2
exit 1
