#!/bin/sh
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out_dir=$self_dir/out
tmp_dir=$(mktemp -d /tmp/stability-adsp-serialize-c1-build.XXXXXX)
verify_dir=$tmp_dir/verify
cleanup() {
	rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

sh -n "$self_dir/install-stability-adsp-serialize-c1.sh"
sh -n "$self_dir/rollback-stability-adsp-serialize-c1.sh"
grep -Fxq 'Wants=cerro-cellular-prepare.service' \
	"$self_dir/cerro-audio-after-cellular.conf"
grep -Fxq 'After=cerro-cellular-prepare.service' \
	"$self_dir/cerro-audio-after-cellular.conf"

install -m 0644 "$self_dir/cerro-audio-after-cellular.conf" \
	"$tmp_dir/cerro-audio-after-cellular.conf"
install -m 0755 "$self_dir/install-stability-adsp-serialize-c1.sh" \
	"$tmp_dir/install-stability-adsp-serialize-c1.sh"
install -m 0755 "$self_dir/rollback-stability-adsp-serialize-c1.sh" \
	"$tmp_dir/rollback-stability-adsp-serialize-c1.sh"

(
	cd "$tmp_dir"
	sha256sum \
		cerro-audio-after-cellular.conf \
		install-stability-adsp-serialize-c1.sh \
		rollback-stability-adsp-serialize-c1.sh \
		>MANIFEST.sha256
	sha256sum -c MANIFEST.sha256
)

mkdir -p "$verify_dir/cerro-audio.service.d"
cat >"$verify_dir/cerro-audio.service" <<'EOF'
[Unit]
Description=Cerro SM8650 ADSP / WSA sound
After=local-fs.target cerro-remoteproc-prepare.service
Before=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
EOF
cat >"$verify_dir/cerro-cellular-prepare.service" <<'EOF'
[Unit]
After=rmtfs.service tqftpserv.service pd-mapper.service cerro-cellular-meta.service
Before=ModemManager.service

[Service]
Type=oneshot
ExecStart=/bin/true
EOF
for unit in cerro-remoteproc-prepare.service rmtfs.service tqftpserv.service \
	pd-mapper.service cerro-cellular-meta.service ModemManager.service; do
	cat >"$verify_dir/$unit" <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
done
install -m 0644 "$self_dir/cerro-audio-after-cellular.conf" \
	"$verify_dir/cerro-audio.service.d/zz-stability-adsp-serialize-c1.conf"
SYSTEMD_UNIT_PATH="$verify_dir:/etc/systemd/system:/usr/lib/systemd/system:/lib/systemd/system" \
	systemd-analyze --generators=no --man=no verify \
	cerro-audio.service cerro-cellular-prepare.service

mkdir -p "$out_dir"
rm -f -- \
	"$out_dir/cerro-audio-after-cellular.conf" \
	"$out_dir/install-stability-adsp-serialize-c1.sh" \
	"$out_dir/rollback-stability-adsp-serialize-c1.sh" \
	"$out_dir/MANIFEST.sha256" \
	"$out_dir/BUILD-AUDIT.txt"
for file in \
	cerro-audio-after-cellular.conf \
	install-stability-adsp-serialize-c1.sh \
	rollback-stability-adsp-serialize-c1.sh \
	MANIFEST.sha256; do
	install -m 0644 "$tmp_dir/$file" "$out_dir/$file"
done
chmod 0755 \
	"$out_dir/install-stability-adsp-serialize-c1.sh" \
	"$out_dir/rollback-stability-adsp-serialize-c1.sh"

{
	echo "stability-adsp-serialize-c1 build audit"
	echo "known audio unit sha256: 7a1405e037865737a061f8ef82e9d4777eae7e190b913d68956a523c3c878ee2"
	echo "known audio script sha256: 6408461ec44c52e1c4a2ede7eb79f917e1b407502f946d313470bc29ccab9c0b"
	echo "known remoteproc unit sha256: 2f01aa9444fd90b1107b46c5491b1b0cf1d91fe7e91da9ad094d1b54014fe749"
	echo "known cellular prepare unit sha256: efeba534f31affe74f6740e74dc94704ee5a934eba4e278a60892ca8e2ff4e69"
	echo "known cellular prepare script sha256: a42092f35ddd866dab60a9df16cd858566866f74b028f817e8745dc72bd7ca0b"
	echo "known no-meta drop-in sha256: 9775f89bb189b38fb3b8c5ed51a151775f885a162e7c0680f4a8ac9b72f55cd8"
	printf "manifest sha256: "
	sha256sum "$out_dir/MANIFEST.sha256" | awk '{print $1}'
	cat "$out_dir/MANIFEST.sha256"
} >"$out_dir/BUILD-AUDIT.txt"

echo "stability-adsp-serialize-c1 output: $out_dir"
cat "$out_dir/BUILD-AUDIT.txt"
