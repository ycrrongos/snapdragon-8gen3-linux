#!/bin/sh
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out_dir=$self_dir/out
tmp_dir=$(mktemp -d /tmp/cellular-modempr-nometa-c1-build.XXXXXX)
cleanup() {
	rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

sh -n "$self_dir/install-cellular-modempr-nometa-c1.sh"
sh -n "$self_dir/rollback-cellular-modempr-nometa-c1.sh"

install -m 0644 "$self_dir/cerro-cellular-meta-noop.conf" \
	"$tmp_dir/cerro-cellular-meta-noop.conf"
install -m 0755 "$self_dir/install-cellular-modempr-nometa-c1.sh" \
	"$tmp_dir/install-cellular-modempr-nometa-c1.sh"
install -m 0755 "$self_dir/rollback-cellular-modempr-nometa-c1.sh" \
	"$tmp_dir/rollback-cellular-modempr-nometa-c1.sh"

(
	cd "$tmp_dir"
	sha256sum \
		cerro-cellular-meta-noop.conf \
		install-cellular-modempr-nometa-c1.sh \
		rollback-cellular-modempr-nometa-c1.sh \
		>MANIFEST.sha256
	sha256sum -c MANIFEST.sha256
)

mkdir -p "$out_dir"
rm -f -- \
	"$out_dir/cerro-cellular-meta-noop.conf" \
	"$out_dir/install-cellular-modempr-nometa-c1.sh" \
	"$out_dir/rollback-cellular-modempr-nometa-c1.sh" \
	"$out_dir/MANIFEST.sha256" \
	"$out_dir/BUILD-AUDIT.txt"
for file in \
	cerro-cellular-meta-noop.conf \
	install-cellular-modempr-nometa-c1.sh \
	rollback-cellular-modempr-nometa-c1.sh \
	MANIFEST.sha256; do
	install -m 0644 "$tmp_dir/$file" "$out_dir/$file"
done
chmod 0755 \
	"$out_dir/install-cellular-modempr-nometa-c1.sh" \
	"$out_dir/rollback-cellular-modempr-nometa-c1.sh"

{
	echo "cellular-modempr-nometa-c1 build audit"
	echo "known meta unit sha256: e053fb258e411414669762fa4bc9a3c1569980be875ae4932e94da07eeaa97ea"
	echo "known meta wrapper sha256: 34cec701b305150be93ead7910da54e6cc3def6a5f8847aa8dbb23a916317f94"
	echo "known meta helper sha256: 46f7ddf72029374d90dbaf2c607078eb2ff278241db88f4a9fc4f5c43df2d541"
	printf "manifest sha256: "
	sha256sum "$out_dir/MANIFEST.sha256" | awk '{print $1}'
	cat "$out_dir/MANIFEST.sha256"
} >"$out_dir/BUILD-AUDIT.txt"

echo "cellular-modempr-nometa-c1 output: $out_dir"
cat "$out_dir/BUILD-AUDIT.txt"
