#!/bin/bash
set -euo pipefail
HOST=192.168.68.1
PORT=8768
KVER=$(uname -r)
D=/lib/modules/$KVER/extra
mkdir -p "$D" /lib/firmware/qcom/sm8650 /tmp/battko
cd /tmp/battko
# expected sizes (filled by host before serve — self-check via curl Content-Length)
declare -A EXP=(
  [cerro-pmic-glink-overlay.ko]=234128
  [pmic_glink.ko]=286016
  [qcom_battmgr.ko]=321592
  [typec_ucsi.ko]=837880
  [ucsi_glink.ko]=303624
  [battmgr.jsn]=516
)
for f in cerro-pmic-glink-overlay.ko pmic_glink.ko qcom_battmgr.ko typec_ucsi.ko ucsi_glink.ko battmgr.jsn; do
  echo "FETCH $f expect=${EXP[$f]}"
  curl --noproxy '*' -fsSL --max-time 120 -o "$f" "http://$HOST:$PORT/$f"
  sz=$(wc -c < "$f")
  echo "GOT $f size=$sz"
  if [ "$sz" -ne "${EXP[$f]}" ]; then
    echo "SIZE_MISMATCH $f"
    exit 12
  fi
done
install -m0644 battmgr.jsn /lib/firmware/qcom/sm8650/battmgr.jsn
install -m0644 battmgr.jsn /lib/firmware/battmgr.jsn
for f in cerro-pmic-glink-overlay.ko pmic_glink.ko qcom_battmgr.ko typec_ucsi.ko ucsi_glink.ko; do
  install -m0644 "$f" "$D/$f"
  ls -l "$D/$f"
done
depmod "$KVER" || true
systemctl restart pd-mapper || true
rmmod qcom_battmgr 2>/dev/null || true
rmmod ucsi_glink 2>/dev/null || true
rmmod typec_ucsi 2>/dev/null || true
rmmod pmic_glink 2>/dev/null || true
rmmod cerro_pmic_glink_overlay 2>/dev/null || true
modprobe cerro-pmic-glink-overlay
sleep 1
modprobe pmic_glink
sleep 2
modprobe qcom_battmgr
sleep 10
echo PSY=$(ls /sys/class/power_supply | tr '\n' ',')
echo CAP=$(cat /sys/class/power_supply/qcom-battmgr-bat/capacity 2>&1 || true)
echo ST=$(cat /sys/class/power_supply/qcom-battmgr-bat/status 2>&1 || true)
echo V=$(cat /sys/class/power_supply/qcom-battmgr-bat/voltage_now 2>&1 || true)
echo I=$(cat /sys/class/power_supply/qcom-battmgr-bat/current_now 2>&1 || true)
echo UON=$(cat /sys/class/power_supply/qcom-battmgr-usb/online 2>&1 || true)
echo UV=$(cat /sys/class/power_supply/qcom-battmgr-usb/voltage_now 2>&1 || true)
echo UI=$(cat /sys/class/power_supply/qcom-battmgr-usb/current_now 2>&1 || true)
# UCSI after basic path
modprobe typec_ucsi || true
modprobe ucsi_glink || true
sleep 5
echo UTYPE=$(cat /sys/class/power_supply/qcom-battmgr-usb/usb_type 2>&1 || true)
echo TYPEC=$(ls /sys/class/typec 2>/dev/null | tr '\n' ',')
dmesg | grep -iE 'cerro-pmic|pmic_glink|battmgr|ucsi|pdr|charger' | tail -50
# aux-hpd-bridge + pmic_glink_altmode: required once mdss_dp0 is okay, else DRM
# component_bind waits forever on DP→aux_bridge→HPD (usb-dp1 black screen).
printf '%s\n' cerro-pmic-glink-overlay aux-hpd-bridge pmic_glink pmic_glink_altmode qcom_battmgr typec_ucsi ucsi_glink > /etc/modules-load.d/cerro-battmgr.conf
cat >/etc/systemd/system/cerro-battmgr.service <<'U'
[Unit]
Description=Cerro battery manager
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/modprobe cerro-pmic-glink-overlay
ExecStart=/bin/sleep 1
ExecStart=/usr/sbin/modprobe aux-hpd-bridge
ExecStart=/usr/sbin/modprobe pmic_glink
ExecStart=/usr/sbin/modprobe pmic_glink_altmode
ExecStart=/bin/sleep 1
ExecStart=/usr/sbin/modprobe qcom_battmgr
ExecStart=/bin/sleep 2
ExecStart=/usr/sbin/modprobe typec_ucsi
ExecStart=/usr/sbin/modprobe ucsi_glink
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable cerro-battmgr.service
echo INSTALL_PASS
