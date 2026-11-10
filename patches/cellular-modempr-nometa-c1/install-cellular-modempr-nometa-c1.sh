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
	'e053fb258e411414669762fa4bc9a3c1569980be875ae4932e94da07eeaa97ea' \
	'/etc/systemd/system/cerro-cellular-meta.service' \
	'34cec701b305150be93ead7910da54e6cc3def6a5f8847aa8dbb23a916317f94' \
	'/usr/local/sbin/cerro-cellular-meta.sh' \
	'46f7ddf72029374d90dbaf2c607078eb2ff278241db88f4a9fc4f5c43df2d541' \
	'/usr/local/libexec/cerro-qmi-dms-set-meta.py' |
	sha256sum -c -

target=/etc/systemd/system/cerro-cellular-meta.service.d/zz-cellular-modempr-nometa-c1.conf
if [ -e "$target" ] || [ -L "$target" ]; then
	if [ ! -f "$target" ] || [ -L "$target" ]; then
		echo "refusing unexpected target: $target" >&2
		exit 1
	fi
	if ! cmp -s cerro-cellular-meta-noop.conf "$target"; then
		echo "refusing different existing target: $target" >&2
		exit 1
	fi
fi

install -D -m 0644 cerro-cellular-meta-noop.conf "$target"
systemctl daemon-reload
sync

echo "cellular-modempr-nometa-c1 installed; no service, setter, remoteproc or reboot action was requested"
