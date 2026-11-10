#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

rm -f -- \
	/etc/systemd/system/rmtfs.service.d/zzz-cerro-rftrace-c1.conf \
	/etc/systemd/system/tqftpserv.service.d/zzz-cerro-rftrace-c1.conf \
	/usr/local/libexec/cerro-rmtfs-rftrace-c1 \
	/usr/local/libexec/cerro-tqftpserv-rftrace-c1
systemctl daemon-reload
sync

echo "cellular-rftrace-c1 files removed; running services were not restarted"
