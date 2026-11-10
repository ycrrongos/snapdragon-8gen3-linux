#!/bin/sh
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out_dir=$self_dir/out
tmp_dir=$(mktemp -d /tmp/cellular-modempr-c1-build.XXXXXX)
cleanup() {
	rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

for script in \
	cerro-modempr-c1 \
	install-cellular-modempr-c1.sh \
	rollback-cellular-modempr-c1.sh; do
	sh -n "$self_dir/$script"
done

install -m 0755 "$self_dir/cerro-modempr-c1" "$tmp_dir/cerro-modempr-c1"
install -m 0644 "$self_dir/cerro-modempr-c1.service" "$tmp_dir/cerro-modempr-c1.service"
install -m 0644 "$self_dir/cerro-modempr-order.conf" "$tmp_dir/cerro-modempr-order.conf"
install -m 0755 "$self_dir/install-cellular-modempr-c1.sh" "$tmp_dir/install-cellular-modempr-c1.sh"
install -m 0755 "$self_dir/rollback-cellular-modempr-c1.sh" "$tmp_dir/rollback-cellular-modempr-c1.sh"

(
	cd "$tmp_dir"
	sha256sum \
		cerro-modempr-c1 \
		cerro-modempr-c1.service \
		cerro-modempr-order.conf \
		install-cellular-modempr-c1.sh \
		rollback-cellular-modempr-c1.sh \
		>MANIFEST.sha256
	sha256sum -c MANIFEST.sha256
)

mkdir -p "$out_dir"
rm -f -- \
	"$out_dir/cerro-modempr-c1" \
	"$out_dir/cerro-modempr-c1.service" \
	"$out_dir/cerro-modempr-order.conf" \
	"$out_dir/install-cellular-modempr-c1.sh" \
	"$out_dir/rollback-cellular-modempr-c1.sh" \
	"$out_dir/MANIFEST.sha256" \
	"$out_dir/BUILD-AUDIT.txt"
for file in \
	cerro-modempr-c1 \
	cerro-modempr-c1.service \
	cerro-modempr-order.conf \
	install-cellular-modempr-c1.sh \
	rollback-cellular-modempr-c1.sh \
	MANIFEST.sha256; do
	install -m 0644 "$tmp_dir/$file" "$out_dir/$file"
done
chmod 0755 \
	"$out_dir/cerro-modempr-c1" \
	"$out_dir/install-cellular-modempr-c1.sh" \
	"$out_dir/rollback-cellular-modempr-c1.sh"

{
	echo "cellular-modempr-c1 build audit"
	echo "stock modem image sha256: 94a504e81b8bdb5fb28622fbdf9fa14be5efa1d392fe67957fee624a73160f4c"
	echo "stock modem_pr files: 196"
	echo "stock modem_pr bytes: 10851893"
	echo "stock modem_pr tree sha256: c22817b43b4ba6eb965d49d1d091d615330eba905fa7f0c10161b1c317c06f4b"
	printf "manifest sha256: "
	sha256sum "$out_dir/MANIFEST.sha256" | awk '{print $1}'
	cat "$out_dir/MANIFEST.sha256"
} >"$out_dir/BUILD-AUDIT.txt"

echo "cellular-modempr-c1 output: $out_dir"
cat "$out_dir/BUILD-AUDIT.txt"

