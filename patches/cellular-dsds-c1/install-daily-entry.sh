#!/bin/sh
set -eu
base=${1:?verified source bundle directory required}
tooldir=${2:?directory containing cerro-cellular-prepare.sh and service required}
test -s "$tooldir/cerro-cellular-prepare.sh"
test -s "$tooldir/cerro-cellular-prepare.service"
test "$(id -u)" = 0
install -d /usr/local/share/cerro-backups/usim-20261110 /usr/local/libexec/cerro-cellular-c1 /usr/local/bin /usr/share/applications
if [ -e /usr/local/sbin/cerro-cellular-prepare.sh ] && [ ! -e /usr/local/share/cerro-backups/usim-20261110/cerro-cellular-prepare.sh ]; then cp /usr/local/sbin/cerro-cellular-prepare.sh /usr/local/share/cerro-backups/usim-20261110/cerro-cellular-prepare.sh; fi
if [ -e /etc/systemd/system/cerro-cellular-prepare.service ] && [ ! -e /usr/local/share/cerro-backups/usim-20261110/cerro-cellular-prepare.service ]; then cp /etc/systemd/system/cerro-cellular-prepare.service /usr/local/share/cerro-backups/usim-20261110/cerro-cellular-prepare.service; fi
install -m 0755 "$tooldir/cerro-cellular-prepare.sh" /usr/local/sbin/cerro-cellular-prepare.sh
install -m 0644 "$tooldir/cerro-cellular-prepare.service" /etc/systemd/system/cerro-cellular-prepare.service
for file in qmi_socket.py sms_pdu.py sms_store.py data_session.py prepare_dual_usim.py cellular_daemon.py; do
    test -s "$base/$file"
    install -m 0755 "$base/$file" "/usr/local/libexec/cerro-cellular-c1/$file"
done
install -m 0755 "$base/cellular_app.py" /usr/local/bin/cerro-cellular
install -m 0644 "$base/cerro-cellular.desktop" /usr/share/applications/cerro-cellular.desktop
install -m 0644 "$base/cerro-cellular-c1.service" /etc/systemd/system/cerro-cellular-c1.service
python3 -m py_compile /usr/local/libexec/cerro-cellular-c1/*.py /usr/local/bin/cerro-cellular
systemctl daemon-reload
systemd-analyze verify cerro-cellular-c1.service
printf '%s\n' 'Daily entry installed; service has not been enabled or started.'
