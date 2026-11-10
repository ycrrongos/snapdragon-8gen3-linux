#!/bin/sh
# Reproduce Cerro's stock AP Meta_Build_ID handoff as soon as DMS appears.
# The Python helper has an exclusive /tmp marker and can send only DMS 0x69.
set -eu

HELPER=/usr/local/libexec/cerro-qmi-dms-set-meta.py

log() {
  echo "cerro-cellular-meta: $*" >/dev/kmsg 2>/dev/null || \
    echo "cerro-cellular-meta: $*"
}

if [ ! -x "$HELPER" ]; then
  log "audited helper missing"
  exit 1
fi

i=0
while [ "$i" -lt 60 ]; do
  route=$(
    /usr/bin/timeout -k 1 2 /usr/bin/qrtr-lookup 2>/dev/null |
      /usr/bin/awk \
        '$1 == 2 && $2 == 1 && $3 == 0 && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ { print $4, $5; exit }'
  )
  set -- $route
  if [ "$#" -eq 2 ]; then
    if "$HELPER" --node "$1" --port "$2" --timeout 5; then
      log "stock AP meta handoff accepted"
      exit 0
    else
      rc=$?
      log "stock AP meta handoff failed rc=$rc; one-shot marker prevents retry"
      exit "$rc"
    fi
  fi

  i=$((i + 1))
  sleep 1
done

log "DMS service unavailable after bounded wait"
exit 1
