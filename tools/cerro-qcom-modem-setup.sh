#!/bin/sh
# Wrap Debian qcom-modem-setup: UIM provisioning required; GNSS/loc best-effort.
# Stock script's last commands are --loc-* which return QMI Internal on Cerro and
# become the shell's exit status (no set -e), marking the oneshot failed.
#
# Cerro also has a ghost / empty physical slot 2 (truncated ICCID) that ModemManager
# treats as primary-sim-slot=2. Enabling then sees "SIM identifier has changed"
# and override-disables in a loop. Power slot 2 off after primary GW select.
set -e
sim_wait_time="${sim_wait_time:-15}"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Drop GNSS/loc lines; fix missing soc0/machine on mainline Cerro.
awk '
  /loc-set-engine-lock/ { next }
  /loc-set-nmea-types/ { next }
  /cat \/sys\/devices\/soc0\/machine/ {
    sub(/cat \/sys\/devices\/soc0\/machine/, "cat /sys/devices/soc0/machine 2>/dev/null")
  }
  { print }
' /usr/bin/qcom-modem-setup >"$tmp"
chmod +x "$tmp"
sim_wait_time="$sim_wait_time" sh "$tmp"
echo "I: cerro-qcom-modem-setup: UIM path done (GNSS/loc skipped)"

# Dual-SIM flap fix: drop secondary session and power off physical slot 2.
# Tolerate NoEffect (already off) / Internal; do not fail the oneshot.
QMI='qmicli --silent -pd qrtr://0'
if $QMI --uim-noop >/dev/null 2>&1; then
	$QMI --uim-change-provisioning-session='session-type=secondary-gw-provisioning,activate=no' \
		>/dev/null 2>&1 || true
	$QMI --uim-sim-power-off=2 >/dev/null 2>&1 || true
	echo "I: cerro-qcom-modem-setup: secondary GW off + slot2 power-off (best-effort)"
else
	echo "W: cerro-qcom-modem-setup: qrtr://0 unavailable for slot2 power-off"
fi
exit 0
