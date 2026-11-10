#!/bin/sh
# Install only an audited same-version daemon. No service restart here.
set -eu
src=${1:?candidate daemon path required}
expected=${2:?expected SHA-256 required}
test "$(id -u)" = 0
test "${#expected}" = 64
test "$(sha256sum "$src" | cut -d' ' -f1)" = "$expected"
base=/usr/local/libexec/cerro-mm-primary-slot-c1
conf=/etc/systemd/system/ModemManager.service.d/zz-cerro-primary-slot-c1.conf
if [ -e "$conf" ]; then
    grep -qx "ExecStart=$base/ModemManager" "$conf"
fi
ldd "$src" | tee /tmp/cerro-mm-primary-slot-c1-ldd.txt
! grep -Eq 'not found|/home/|/tmp/' /tmp/cerro-mm-primary-slot-c1-ldd.txt
"$src" --version | grep -qx 'ModemManager 1.24.0'
install -d "$base" /etc/systemd/system/ModemManager.service.d
install -m 0755 "$src" "$base/ModemManager"
printf '[Service]\nExecStart=\nExecStart=%s/ModemManager\n' "$base" > "$conf"
chmod 0644 "$conf"
systemctl daemon-reload
systemd-analyze verify ModemManager.service
sha256sum "$base/ModemManager"
systemctl show ModemManager.service -p ExecStart
