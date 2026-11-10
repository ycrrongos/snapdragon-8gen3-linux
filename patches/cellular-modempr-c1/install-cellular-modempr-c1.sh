#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$bundle_dir"
sha256sum -c MANIFEST.sha256

link_path=/lib/firmware/qcom/sm8650/modem_pr
link_target=/run/cerro-modempr-c1/image/modem_pr
if [ -e "$link_path" ] || [ -L "$link_path" ]; then
	if [ ! -L "$link_path" ] || [ "$(readlink "$link_path")" != "$link_target" ]; then
		echo "refusing existing non-candidate path: $link_path" >&2
		exit 1
	fi
fi
if mountpoint -q /run/cerro-modempr-c1; then
	echo "refusing unexpected live candidate mount before install" >&2
	exit 1
fi

install -D -m 0755 cerro-modempr-c1 \
	/usr/local/libexec/cerro-modempr-c1
install -D -m 0644 cerro-modempr-c1.service \
	/etc/systemd/system/cerro-modempr-c1.service
install -D -m 0644 cerro-modempr-order.conf \
	/etc/systemd/system/cerro-remoteproc-prepare.service.d/zz-cerro-modempr-c1.conf

mkdir -p "$(dirname "$link_path")"
if [ ! -L "$link_path" ]; then
	ln -s "$link_target" "$link_path"
fi

systemctl daemon-reload
sync

echo "cellular-modempr-c1 installed; no mount, service start, remoteproc restart or reboot was requested"

