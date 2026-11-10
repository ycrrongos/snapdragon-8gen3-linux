#!/usr/bin/env bash
# Install USB udev rules for Qualcomm 9008 / ZTE EDL (needs sudo).
set -euo pipefail
TOOL="$(cd "$(dirname "$0")" && pwd)"
DRIVERS="$TOOL/edl/Drivers"

sudo cp "$DRIVERS/51-edl.rules" /etc/udev/rules.d/
sudo cp "$DRIVERS/50-android.rules" /etc/udev/rules.d/50-android-edl.rules
# Also allow ZTE memorydump / DFU bulk so we can at least see it
sudo tee /etc/udev/rules.d/52-zte-edl.rules >/dev/null <<'EOF'
# ZTE QUSB_BULK / memorydump / DFU (not true 9008, but useful)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="19d2", ATTRS{idProduct}=="0112", MODE="0666", TAG+="uaccess", GROUP="plugdev"
# Qualcomm EDL
SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", ATTRS{idProduct}=="9008", MODE="0666", TAG+="uaccess", GROUP="plugdev"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", ATTRS{idProduct}=="900e", MODE="0666", TAG+="uaccess", GROUP="plugdev"
EOF

if [[ -f "$DRIVERS/blacklist-qcserial.conf" ]]; then
  sudo cp "$DRIVERS/blacklist-qcserial.conf" /etc/modprobe.d/
fi

sudo udevadm control --reload-rules
sudo udevadm trigger
echo "udev OK. 重新插拔手机 USB。"
lsusb | grep -iE '9008|19d2|05c6' || true
