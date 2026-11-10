#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=/etc/systemd/system/cerro-audio.service.d/zz-stability-adsp-serialize-c1.conf

if [ -e "$target" ] || [ -L "$target" ]; then
	if [ ! -f "$target" ] || [ -L "$target" ] || \
		! cmp -s "$bundle_dir/cerro-audio-after-cellular.conf" "$target"; then
		echo "refusing unexpected target: $target" >&2
		exit 1
	fi
	rm -f -- "$target"
fi

systemctl daemon-reload
sync

echo "stability-adsp-serialize-c1 drop-in removed; no service, remoteproc, setter or reboot action was requested"
