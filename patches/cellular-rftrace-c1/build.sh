#!/bin/sh
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
aosp_root=${AOSP_ROOT:-/mnt/data/aosp}
source_dir="$self_dir/sources"
out_dir="$self_dir/out"
musl_sysroot="$aosp_root/prebuilts/build-tools/sysroots/aarch64-unknown-linux-musl"
clang_bin="$aosp_root/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang"
ar_bin="$aosp_root/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-ar"
qrtr_dir="$aosp_root/device/linaro/dragonboard/shared/utils/qrtr/lib"
qrtr_ns="$aosp_root/device/linaro/dragonboard/shared/utils/qrtr/src/ns.h"
zstd_dir="$aosp_root/external/zstd/lib"

for path in \
	"$source_dir/rmtfs_1.1.orig.tar.gz" \
	"$source_dir/rmtfs_1.1-4.debian.tar.xz" \
	"$source_dir/tqftpserv_1.1.orig.tar.gz" \
	"$source_dir/tqftpserv_1.1-4.debian.tar.xz" \
	"$musl_sysroot/lib/libc.a" \
	"$clang_bin" \
	"$ar_bin" \
	"$qrtr_dir/qrtr.c" \
	"$qrtr_dir/qmi.c" \
	"$qrtr_dir/logging.c" \
	"$qrtr_ns" \
	"$zstd_dir/Makefile"; do
	[ -f "$path" ] || { echo "missing input: $path" >&2; exit 1; }
done

(
	cd "$source_dir"
	printf '%s  %s\n' \
		3d9d37cd573a44acf9c10897b59a3f9a359c0bcf2f02d9e2b4605f6cdf4ed5c5 rmtfs_1.1.orig.tar.gz \
		d1d66cda57cd5e39c3f8cc29c8305b8dfcd33508db1e99033127ce108d1905e2 rmtfs_1.1-4.debian.tar.xz \
		a7ebf03aa19e5deabcb499836ccf7378a0cd65452232f87406790a5509421527 tqftpserv_1.1.orig.tar.gz \
		7d2ca318eb8851770917413b7aa19824e5bfda6856dddba1a150fecc7443d27a tqftpserv_1.1-4.debian.tar.xz | sha256sum -c -
)

build_once()
{
	build_root=$1
	mkdir -p "$build_root/rmtfs" "$build_root/tqftpserv" "$build_root/qrtr" "$build_root/zstd"
	tar -xzf "$source_dir/rmtfs_1.1.orig.tar.gz" -C "$build_root/rmtfs" --strip-components=1
	tar -xJf "$source_dir/rmtfs_1.1-4.debian.tar.xz" -C "$build_root/rmtfs"
	tar -xzf "$source_dir/tqftpserv_1.1.orig.tar.gz" -C "$build_root/tqftpserv" --strip-components=1
	tar -xJf "$source_dir/tqftpserv_1.1-4.debian.tar.xz" -C "$build_root/tqftpserv"

	while IFS= read -r patch_name; do
		[ -n "$patch_name" ] || continue
		patch -s -d "$build_root/rmtfs" -p1 < "$build_root/rmtfs/debian/patches/$patch_name"
	done < "$build_root/rmtfs/debian/patches/series"
	while IFS= read -r patch_name; do
		[ -n "$patch_name" ] || continue
		patch -s -d "$build_root/tqftpserv" -p1 < "$build_root/tqftpserv/debian/patches/$patch_name"
	done < "$build_root/tqftpserv/debian/patches/series"
	patch -s -d "$build_root/rmtfs" -p1 < "$self_dir/rmtfs-rftrace.patch"
	patch -s -d "$build_root/tqftpserv" -p1 < "$self_dir/tqftpserv-rftrace.patch"

	cp "$qrtr_dir/libqrtr.h" "$qrtr_dir/qrtr.c" "$qrtr_dir/qmi.c" \
		"$qrtr_dir/logging.c" "$qrtr_dir/logging.h" "$qrtr_ns" \
		"$build_root/qrtr/"
	cp -a "$zstd_dir/." "$build_root/zstd/"

	cc_common="--target=aarch64-unknown-linux-musl --sysroot=$musl_sysroot -nostdinc -isystem $musl_sysroot/include -L$musl_sysroot/lib -fuse-ld=lld -rtlib=compiler-rt"
	common_cflags="-static -O2 -g0 -ffile-prefix-map=$build_root=. -fdebug-prefix-map=$build_root=."
	make -s -C "$build_root/zstd" libzstd.a \
		CC="$clang_bin $cc_common" AR="$ar_bin" \
		ZSTD_LIB_COMPRESSION=0 ZSTD_LIB_DICTBUILDER=0 \
		ZSTD_LIB_DEPRECATED=0 ZSTD_LEGACY_SUPPORT=0 \
		CFLAGS="-O2 -g0 -DZSTD_DISABLE_ASM=1 -DZSTD_NO_INTRINSICS=1 -DXXH_VECTOR=0 -ffile-prefix-map=$build_root=. -fdebug-prefix-map=$build_root=."

	# shellcheck disable=SC2086
	"$clang_bin" $cc_common $common_cflags -DANDROID -Wall -Wextra \
		-I"$build_root/qrtr" -I"$build_root/rmtfs" \
		"$build_root/qrtr/qrtr.c" "$build_root/qrtr/qmi.c" "$build_root/qrtr/logging.c" \
		"$build_root/rmtfs/qmi_rmtfs.c" "$build_root/rmtfs/rmtfs.c" \
		"$build_root/rmtfs/rproc.c" "$build_root/rmtfs/sharedmem.c" \
		"$build_root/rmtfs/storage.c" "$build_root/rmtfs/util.c" \
		-pthread -Wl,--build-id=sha1 -o "$build_root/cerro-rmtfs-rftrace-c1"

	# tqftpserv keeps Debian's zstd firmware fallback; only path/result metadata is added.
	# shellcheck disable=SC2086
	"$clang_bin" $cc_common $common_cflags -D_GNU_SOURCE -Wno-macro-redefined -Wall -Wextra \
		-I"$build_root/qrtr" -I"$build_root/tqftpserv" -I"$build_root/zstd" \
		"$build_root/qrtr/qrtr.c" "$build_root/qrtr/logging.c" \
		"$build_root/tqftpserv/tqftpserv.c" "$build_root/tqftpserv/translate.c" \
		"$build_root/tqftpserv/zstd-decompress.c" "$build_root/zstd/libzstd.a" \
		-pthread -Wl,--build-id=sha1 -o "$build_root/cerro-tqftpserv-rftrace-c1"
}

first=$(mktemp -d /tmp/cerro-rftrace-c1.first.XXXXXX)
second=$(mktemp -d /tmp/cerro-rftrace-c1.second.XXXXXX)
trap 'rm -rf -- "$first" "$second"' EXIT HUP INT TERM
build_once "$first"
build_once "$second"
cmp "$first/cerro-rmtfs-rftrace-c1" "$second/cerro-rmtfs-rftrace-c1"
cmp "$first/cerro-tqftpserv-rftrace-c1" "$second/cerro-tqftpserv-rftrace-c1"

mkdir -p "$out_dir"
rm -f -- \
	"$out_dir/cerro-rmtfs-rftrace-c1" \
	"$out_dir/cerro-tqftpserv-rftrace-c1" \
	"$out_dir/rmtfs-rftrace.conf" \
	"$out_dir/tqftpserv-rftrace.conf" \
	"$out_dir/install-cellular-rftrace-c1.sh" \
	"$out_dir/rollback-cellular-rftrace-c1.sh" \
	"$out_dir/MANIFEST.sha256" \
	"$out_dir/BUILD-AUDIT.txt"
install -m 0755 "$first/cerro-rmtfs-rftrace-c1" "$out_dir/cerro-rmtfs-rftrace-c1"
install -m 0755 "$first/cerro-tqftpserv-rftrace-c1" "$out_dir/cerro-tqftpserv-rftrace-c1"
install -m 0644 "$self_dir/rmtfs-rftrace.conf" "$out_dir/rmtfs-rftrace.conf"
install -m 0644 "$self_dir/tqftpserv-rftrace.conf" "$out_dir/tqftpserv-rftrace.conf"
install -m 0755 "$self_dir/install-cellular-rftrace-c1.sh" "$out_dir/install-cellular-rftrace-c1.sh"
install -m 0755 "$self_dir/rollback-cellular-rftrace-c1.sh" "$out_dir/rollback-cellular-rftrace-c1.sh"

(
	cd "$out_dir"
	sha256sum \
		cerro-rmtfs-rftrace-c1 \
		cerro-tqftpserv-rftrace-c1 \
		rmtfs-rftrace.conf \
		tqftpserv-rftrace.conf \
		install-cellular-rftrace-c1.sh \
		rollback-cellular-rftrace-c1.sh > MANIFEST.sha256
)

{
	echo "cellular-rftrace-c1 build audit"
	echo "Debian rmtfs orig sha256: 3d9d37cd573a44acf9c10897b59a3f9a359c0bcf2f02d9e2b4605f6cdf4ed5c5"
	echo "Debian rmtfs delta sha256: d1d66cda57cd5e39c3f8cc29c8305b8dfcd33508db1e99033127ce108d1905e2"
	echo "Debian tqftpserv orig sha256: a7ebf03aa19e5deabcb499836ccf7378a0cd65452232f87406790a5509421527"
	echo "Debian tqftpserv delta sha256: 7d2ca318eb8851770917413b7aa19824e5bfda6856dddba1a150fecc7443d27a"
	sha256sum "$self_dir/rmtfs-rftrace.patch" "$self_dir/tqftpserv-rftrace.patch"
	sha256sum "$qrtr_dir/libqrtr.h" "$qrtr_dir/qrtr.c" "$qrtr_dir/qmi.c" "$qrtr_dir/logging.c" "$qrtr_dir/logging.h" "$qrtr_ns"
	sha256sum "$zstd_dir/Makefile" "$zstd_dir/libzstd.mk" "$zstd_dir/zstd.h"
	sha256sum "$clang_bin" "$ar_bin" "$musl_sysroot/lib/libc.a"
	file "$out_dir/cerro-rmtfs-rftrace-c1" "$out_dir/cerro-tqftpserv-rftrace-c1"
	readelf -h -l -d "$out_dir/cerro-rmtfs-rftrace-c1"
	readelf -h -l -d "$out_dir/cerro-tqftpserv-rftrace-c1"
	cat "$out_dir/MANIFEST.sha256"
} > "$out_dir/BUILD-AUDIT.txt"

echo "PASS: reproducible cellular-rftrace-c1 bundle at $out_dir"
cat "$out_dir/MANIFEST.sha256"
