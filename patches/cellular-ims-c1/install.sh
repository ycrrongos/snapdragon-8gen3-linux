#!/bin/bash
# Install Cerro IMS persistence (run on phone as root, or via cerro-ssh + sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

install -d /etc/systemd/system/81voltd.service.d
install -m 644 "$ROOT/systemd/81voltd.service.d/override.conf" \
  /etc/systemd/system/81voltd.service.d/override.conf
install -m 644 "$ROOT/systemd/cerro-qcom-imsd.service" \
  /etc/systemd/system/cerro-qcom-imsd.service
install -m 755 "$ROOT/scripts/cerro-ims-iface.sh" /usr/local/sbin/cerro-ims-iface.sh

# NM dispatcher: after gsm up, fix IMS mux
install -d /etc/NetworkManager/dispatcher.d
cat >/etc/NetworkManager/dispatcher.d/98-cerro-ims-iface <<'EOF'
#!/bin/bash
[ "$2" = "up" ] || [ "$2" = "dhcp6-change" ] || [ "$2" = "connectivity-change" ] || exit 0
/usr/local/sbin/cerro-ims-iface.sh || true
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/98-cerro-ims-iface

# Apply qcom-imsd source patches if tree present
if [ -d /home/rong/src/qcom-imsd/src/qcom_imsd ]; then
  cp -a "$ROOT/qcom-imsd-patches/"*.py /home/rong/src/qcom-imsd/src/qcom_imsd/
  cp -a "$ROOT/qcom-imsd-patches/imsd.toml" /home/rong/src/qcom-imsd/imsd.toml
  chown -R rong:rong /home/rong/src/qcom-imsd/src/qcom_imsd /home/rong/src/qcom-imsd/imsd.toml
fi

systemctl daemon-reload
systemctl enable --now 81voltd.service
systemctl enable --now cerro-qcom-imsd.service
/usr/local/sbin/cerro-ims-iface.sh || true
echo "cellular-ims-c1 installed"
