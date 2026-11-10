#!/bin/sh
# Ensure NM WWAN radio stays enabled. State file can linger as disabled after
# accidental "nmcli radio wwan off", which then kills a healthy MM modem.
case "$2" in
  up|connectivity-change|hostname) ;;
  *) exit 0 ;;
esac
command -v nmcli >/dev/null 2>&1 || exit 0
nmcli -t -f WWAN radio | grep -qx enabled && exit 0
nmcli radio wwan on >/dev/null 2>&1 || true
