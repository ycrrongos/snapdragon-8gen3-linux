#!/bin/bash
set -euo pipefail
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[[ $(id -u) = 0 ]] || { echo 'Run as root on the phone'; exit 1; }
[[ $# = 2 ]] || { echo 'Usage: install-on-phone.sh PRIVATE_EEPROM64 EXPECTED_SHA256'; exit 1; }
calibration_source=$1
calibration_sha=$2
printf '%s  %s\n' "$calibration_sha" "$calibration_source" | sha256sum -c -
[[ $(stat -c %s "$calibration_source") = 64 ]]
backup=/usr/local/share/cerro-backups/camera-startup-20261110
install -d -m700 "$backup" /var/lib/cerro-camera
for file in /etc/systemd/system/cerro-camss-load.service /etc/modprobe.d/cerro-camss.conf; do
  [[ ! -e $backup/$(basename "$file") ]] || { echo 'Existing startup backup; inspect before reinstall'; exit 1; }
  cp "$file" "$backup/"
done
install -m600 "$calibration_source" /var/lib/cerro-camera/imx800-eeprom-first64.bin
python3 - "$calibration_sha" <<'PY'
import json,sys
from pathlib import Path
p=Path('/var/lib/cerro-camera/unit.json')
p.write_text(json.dumps({'sha256':sys.argv[1],'source':'Read from this handset IMX800 EEPROM'},indent=2)+'\n')
p.chmod(0o600)
PY
install -D -m755 "$base/start-camera.py" /usr/local/libexec/cerro-camera/start-camera.py
/usr/local/libexec/cerro-camera/start-camera.py --check-calibration
install -m644 "$base/cerro-camss-load.service" /etc/systemd/system/cerro-camss-load.service
install -m644 "$base/cerro-camss.conf" /etc/modprobe.d/cerro-camss.conf
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/cerro-camss-load.service
systemctl reenable cerro-camss-load.service
echo 'Installed normal multi-user camera dependency chain; validate on next boot.'
