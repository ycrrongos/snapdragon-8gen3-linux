#!/bin/bash
# Bring up MM IMS bearer iface (qmapmux0.N) — MM often leaves it DOWN.
# Also create+connect apn=ims if none is connected (81voltd alone is flaky after races).
set -euo pipefail
LOGTAG=cerro-ims-iface

have_ims=0
for path in /org/freedesktop/ModemManager1/Bearer/*; do
  [ -e "$path" ] || continue
  id="${path##*/}"
  out=$(mmcli -b "$id" 2>/dev/null) || continue
  echo "$out" | grep -qi "apn: *ims" || continue
  if echo "$out" | grep -qi "connected: *yes"; then
    have_ims=1
  fi
done

if [ "$have_ims" != 1 ]; then
  # Do not fight 81voltd mid-connect; only create if nothing IMS exists.
  if ! mmcli -m any 2>/dev/null | grep -qi "apn: *ims"; then
    bid=$(mmcli -m any --create-bearer='apn=ims,ip-type=ipv6' 2>/dev/null | sed -n 's|.*/Bearer/\([0-9]*\).*|\1|p' || true)
    if [ -n "${bid:-}" ]; then
      mmcli -b "$bid" --connect 2>/dev/null || true
      logger -t "$LOGTAG" "created/connected IMS bearer $bid"
    fi
  fi
fi

for path in /org/freedesktop/ModemManager1/Bearer/*; do
  [ -e "$path" ] || continue
  id="${path##*/}"
  out=$(mmcli -b "$id" 2>/dev/null) || continue
  echo "$out" | grep -qi "apn: *ims" || continue
  echo "$out" | grep -qi "connected: *yes" || continue
  iface=$(echo "$out" | awk -F: '/interface:/{gsub(/ /,"",$2); print $2; exit}')
  addr=$(echo "$out" | awk '/IPv6 configuration/{p=1} p&&/address:/{print $NF; exit}')
  gw=$(echo "$out" | awk '/IPv6 configuration/{p=1} p&&/gateway:/{print $NF; exit}')
  [ -n "${iface:-}" ] || continue
  ip link set "$iface" up || true
  if [ -n "${addr:-}" ]; then
    ip -6 addr replace "$addr/64" dev "$iface" || true
  fi
  # Do NOT install a default route on the IMS bearer. That races WWAN data
  # (often steals qmapmux0.0 / leaves data DOWN) and breaks mobile internet.
  # Keep only link-local reachability for the IMS PDN.
  if [ -n "${gw:-}" ]; then
    ip -6 route replace "$gw"/128 dev "$iface" 2>/dev/null || true
  fi
  logger -t "$LOGTAG" "up $iface addr=${addr:-?} gw=${gw:-?} (no default route)"
done
