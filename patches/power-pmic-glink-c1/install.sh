#!/bin/bash
# Install battery modules onto live Cerro Debian (root).
set -euo pipefail
KVER=$(uname -r)
SRC=${1:-/tmp/battko}
D=/lib/modules/$KVER/extra
mkdir -p "$D"
for f in cerro-pmic-glink-overlay.ko pmic_glink.ko qcom_battmgr.ko typec_ucsi.ko ucsi_glink.ko; do
  [[ -f $SRC/$f ]] || { echo "missing $SRC/$f" >&2; exit 1; }
  install -m 0644 "$SRC/$f" "$D/$f"
done
install -m 0644 "$(dirname "$0")/cerro-battmgr.service" /etc/systemd/system/cerro-battmgr.service
# Prefer loading typec before ucsi_glink
sed -i 's|ExecStart=/usr/sbin/modprobe ucsi_glink|ExecStart=/usr/sbin/modprobe typec_ucsi\nExecStart=/usr/sbin/modprobe ucsi_glink|' \
  /etc/systemd/system/cerro-battmgr.service 2>/dev/null || true
depmod "$KVER"
systemctl daemon-reload
systemctl enable --now cerro-battmgr.service
sleep 2
ls /sys/class/power_supply/
for a in status capacity voltage_now current_now; do
  echo "bat.$a=$(cat /sys/class/power_supply/qcom-battmgr-bat/$a 2>&1 || true)"
done
