#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$bundle_dir"
sha256sum -c MANIFEST.sha256

printf '%s  %s\n' \
	'7a1405e037865737a061f8ef82e9d4777eae7e190b913d68956a523c3c878ee2' \
	'/etc/systemd/system/cerro-audio.service' \
	'6408461ec44c52e1c4a2ede7eb79f917e1b407502f946d313470bc29ccab9c0b' \
	'/usr/local/sbin/cerro-audio-up.sh' \
	'2f01aa9444fd90b1107b46c5491b1b0cf1d91fe7e91da9ad094d1b54014fe749' \
	'/etc/systemd/system/cerro-remoteproc-prepare.service' \
	'efeba534f31affe74f6740e74dc94704ee5a934eba4e278a60892ca8e2ff4e69' \
	'/etc/systemd/system/cerro-cellular-prepare.service' \
	'a42092f35ddd866dab60a9df16cd858566866f74b028f817e8745dc72bd7ca0b' \
	'/usr/local/sbin/cerro-cellular-prepare.sh' \
	'9775f89bb189b38fb3b8c5ed51a151775f885a162e7c0680f4a8ac9b72f55cd8' \
	'/etc/systemd/system/cerro-cellular-meta.service.d/zz-cellular-modempr-nometa-c1.conf' |
	sha256sum -c -

target=/etc/systemd/system/cerro-audio.service.d/zz-stability-adsp-serialize-c1.conf
if [ -e "$target" ] || [ -L "$target" ]; then
	if [ ! -f "$target" ] || [ -L "$target" ]; then
		echo "refusing unexpected target: $target" >&2
		exit 1
	fi
	if ! cmp -s cerro-audio-after-cellular.conf "$target"; then
		echo "refusing different existing target: $target" >&2
		exit 1
	fi
fi

install -D -m 0644 cerro-audio-after-cellular.conf "$target"
systemctl daemon-reload
sync

echo "stability-adsp-serialize-c1 installed; no service, remoteproc, setter or reboot action was requested"
