#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$bundle_dir"
sha256sum -c MANIFEST.sha256

install -D -m 0755 cerro-rmtfs-rftrace-c1 \
	/usr/local/libexec/cerro-rmtfs-rftrace-c1
install -D -m 0755 cerro-tqftpserv-rftrace-c1 \
	/usr/local/libexec/cerro-tqftpserv-rftrace-c1
install -D -m 0644 rmtfs-rftrace.conf \
	/etc/systemd/system/rmtfs.service.d/zzz-cerro-rftrace-c1.conf
install -D -m 0644 tqftpserv-rftrace.conf \
	/etc/systemd/system/tqftpserv.service.d/zzz-cerro-rftrace-c1.conf

systemctl daemon-reload
sync

echo "cellular-rftrace-c1 installed; no service was restarted and no reboot was requested"
