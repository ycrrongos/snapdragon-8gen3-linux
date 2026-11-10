#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

link_path=/lib/firmware/qcom/sm8650/modem_pr
link_target=/run/cerro-modempr-c1/image/modem_pr
if systemctl is-active --quiet cerro-modempr-c1.service || \
	mountpoint -q /run/cerro-modempr-c1; then
	echo "refusing rollback while the candidate mount is active" >&2
	exit 1
fi
if [ -e "$link_path" ] || [ -L "$link_path" ]; then
	if [ ! -L "$link_path" ] || [ "$(readlink "$link_path")" != "$link_target" ]; then
		echo "refusing unexpected path at $link_path" >&2
		exit 1
	fi
	rm -f -- "$link_path"
fi

rm -f -- \
	/etc/systemd/system/cerro-remoteproc-prepare.service.d/zz-cerro-modempr-c1.conf \
	/etc/systemd/system/cerro-modempr-c1.service \
	/usr/local/libexec/cerro-modempr-c1
systemctl daemon-reload
sync

echo "cellular-modempr-c1 inactive files removed; no service or remoteproc was restarted"

