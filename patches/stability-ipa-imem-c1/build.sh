#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/../.." && pwd)"
BASE_REL=build/boot_repack/boot-v2-disp-dpu-s5gb-debian-cellular-c3-memshare.img
STOCK_REL=/mnt/data/aosp/out/target/product/cerro/obj/DTB_OBJ/arch/arm64/boot/dts/vendor/qcom/data/pineapple-ipa.dtbo
OUT_REL=patches/stability-ipa-imem-c1/out/boot-v2-disp-dpu-s5gb-debian-stability-ipa-imem-c1.img
DTB_REL=patches/stability-ipa-imem-c1/out/sm8650-nubia-cerro-stability-ipa-imem-c1.dtb
BASE="$PROJECT/$BASE_REL"
STOCK="$STOCK_REL"
OUT="$PROJECT/$OUT_REL"
OUT_DTB="$PROJECT/$DTB_REL"

BASE_SHA=211bfa98e499e683181a67d6f5c140bc9a96ab2074e91e1a12e2b9fcd335cdf5
STOCK_SHA=3d7bdda8d683b5b1c74e1ac0c719ea9e7eecf3e5404e138ed7da7ba536f25bdf
BASE_DTB_SHA=af7050784f1b17b9502389e768c7ca393249c7e3e353d8ade6682cf806dbb291
BASE_KERNEL_SHA=ee2b15e1853278b0aa7674afff599217125564172e0db98597db18a878d5071f
BASE_RAMDISK_SHA=d968942476f424ddd4611ef1e987f70562903945fd83510fd2bf17f8792d828c
PATCHED_DTB_SHA=2ca6b1c8e24d33b7160c777292fd3a78e43dbefb2ca18348e492e58925320d9b
DTB_SIZE=139075
KERNEL_SIZE=77864771
RAMDISK_SIZE=127
IMAGE_SIZE=77725696
BUILTIN_DTB_OFFSET=19460096
APPENDED_DTB_OFFSET=77725696
DTB_DIFF_OFFSET=104907
BOOT_HEADER_ID_FIRST=577
BOOT_DTB_OFFSET=77873152
CMDLINE='ignore_loglevel pd_ignore_unused clk_ignore_unused console=ttyMSM0,115200n8 earlycon=qcom_geni,0x0089c000 pmos_boot_uuid=0ad60230-638c-49c0-9c95-ab8938f81eaf pmos_root_uuid=ab3a863b-512a-447e-a35c-e681ce0ae61b pmos_rootfsopts=defaults cerro_userland=debian'

for tool in unpack_bootimg mkbootimg fdtget fdtput sha256sum cmp dd stat python3; do
	command -v "$tool" >/dev/null
done

printf '%s  %s\n' "$BASE_SHA" "$BASE" | sha256sum -c -
printf '%s  %s\n' "$STOCK_SHA" "$STOCK" | sha256sum -c -

tmp="$(mktemp -d /tmp/cerro-stability-ipa-imem-c1.XXXXXX)"
printf 'temporary audit tree retained at %s\n' "$tmp"
mkdir -p "$PROJECT/patches/stability-ipa-imem-c1/out" "$tmp/base" "$tmp/verify"

unpack_bootimg --boot_img "$BASE" --out "$tmp/base" \
	--format=mkbootimg >"$tmp/base/mkbootimg-args.txt"

printf '%s  %s\n' "$BASE_DTB_SHA" "$tmp/base/dtb" | sha256sum -c -
printf '%s  %s\n' "$BASE_KERNEL_SHA" "$tmp/base/kernel" | sha256sum -c -
printf '%s  %s\n' "$BASE_RAMDISK_SHA" "$tmp/base/ramdisk" | sha256sum -c -
[[ "$(stat -c %s "$tmp/base/dtb")" == "$DTB_SIZE" ]]
[[ "$(stat -c %s "$tmp/base/kernel")" == "$KERNEL_SIZE" ]]
[[ "$(stat -c %s "$tmp/base/ramdisk")" == "$RAMDISK_SIZE" ]]
[[ "$(fdtget -tx "$tmp/base/dtb" \
	/soc@0/sram@14680000/modem-tables@8000 reg)" == "8000 2000" ]]

mkbootimg \
	--header_version 2 --os_version 16.0.0 --os_patch_level 2026-07 \
	--kernel "$tmp/base/kernel" --ramdisk "$tmp/base/ramdisk" \
	--dtb "$tmp/base/dtb" --pagesize 4096 --base 0 \
	--kernel_offset 0x8000 --ramdisk_offset 0x01000000 \
	--second_offset 0 --tags_offset 0x100 --dtb_offset 0x01f00000 \
	--board '' --cmdline "$CMDLINE" -o "$tmp/repacked-base.img"
cmp "$BASE" "$tmp/repacked-base.img"

python3 - "$tmp/base/kernel" "$DTB_SIZE" "$BUILTIN_DTB_OFFSET" \
	"$APPENDED_DTB_OFFSET" "$IMAGE_SIZE" <<'PY'
import struct
import sys

path, size, builtin, appended, image_size = sys.argv[1:]
size = int(size)
builtin = int(builtin)
appended = int(appended)
image_size = int(image_size)
blob = open(path, "rb").read()
if len(blob) != 77864771:
    raise SystemExit("unexpected kernel component size")
if blob[0x38:0x3c] != b"ARMd":
    raise SystemExit("missing arm64 Image magic")
if struct.unpack_from("<Q", blob, 0x10)[0] != image_size:
    raise SystemExit("unexpected arm64 ImageSize")
hits = []
pos = 0
magic = b"\xd0\x0d\xfe\xed"
while True:
    pos = blob.find(magic, pos)
    if pos < 0:
        break
    if pos + 8 <= len(blob):
        total = struct.unpack_from(">I", blob, pos + 4)[0]
        if 0x1000 <= total <= 0x100000 and pos + total <= len(blob):
            hits.append((pos, total))
    pos += 1
if hits != [(builtin, size), (appended, size)]:
    raise SystemExit(f"unexpected DTB candidates: {hits}")
PY

dd if="$tmp/base/kernel" of="$tmp/builtin.dtb" bs=1 \
	skip="$BUILTIN_DTB_OFFSET" count="$DTB_SIZE" status=none
dd if="$tmp/base/kernel" of="$tmp/appended.dtb" bs=1 \
	skip="$APPENDED_DTB_OFFSET" count="$DTB_SIZE" status=none
cmp "$tmp/base/dtb" "$tmp/builtin.dtb"
cmp "$tmp/base/dtb" "$tmp/appended.dtb"

cp "$tmp/base/dtb" "$tmp/patched.dtb"
fdtput -t x "$tmp/patched.dtb" \
	/soc@0/sram@14680000/modem-tables@8000 reg 0x3000 0x2000
[[ "$(stat -c %s "$tmp/patched.dtb")" == "$DTB_SIZE" ]]
[[ "$(fdtget -tx "$tmp/patched.dtb" \
	/soc@0/sram@14680000/modem-tables@8000 reg)" == "3000 2000" ]]
printf '%s  %s\n' "$PATCHED_DTB_SHA" "$tmp/patched.dtb" | sha256sum -c -
python3 - "$tmp/base/dtb" "$tmp/patched.dtb" "$DTB_DIFF_OFFSET" <<'PY'
import sys

old_path, new_path, expected_pos = sys.argv[1:]
old = open(old_path, "rb").read()
new = open(new_path, "rb").read()
diff = [(i + 1, a, b) for i, (a, b) in enumerate(zip(old, new)) if a != b]
if len(old) != len(new) or diff != [(int(expected_pos), 0x80, 0x30)]:
    raise SystemExit(f"unexpected DTB delta: lengths={len(old)}/{len(new)} diff={diff}")
PY

cp "$tmp/base/kernel" "$tmp/patched.kernel"
dd if="$tmp/patched.dtb" of="$tmp/patched.kernel" bs=1 \
	seek="$BUILTIN_DTB_OFFSET" conv=notrunc status=none
dd if="$tmp/patched.dtb" of="$tmp/patched.kernel" bs=1 \
	seek="$APPENDED_DTB_OFFSET" conv=notrunc status=none
[[ "$(stat -c %s "$tmp/patched.kernel")" == "$KERNEL_SIZE" ]]

python3 - "$tmp/base/kernel" "$tmp/patched.kernel" \
	"$BUILTIN_DTB_OFFSET" "$APPENDED_DTB_OFFSET" "$DTB_DIFF_OFFSET" <<'PY'
import sys

old_path, new_path, builtin, appended, dtb_pos = sys.argv[1:]
old = open(old_path, "rb").read()
new = open(new_path, "rb").read()
dtb_pos = int(dtb_pos)
expected = [int(builtin) + dtb_pos, int(appended) + dtb_pos]
diff = [(i + 1, a, b) for i, (a, b) in enumerate(zip(old, new)) if a != b]
want = [(expected[0], 0x80, 0x30), (expected[1], 0x80, 0x30)]
if len(old) != len(new) or diff != want:
    raise SystemExit(f"unexpected kernel delta: lengths={len(old)}/{len(new)} diff={diff}")
PY

mkbootimg \
	--header_version 2 --os_version 16.0.0 --os_patch_level 2026-07 \
	--kernel "$tmp/patched.kernel" --ramdisk "$tmp/base/ramdisk" \
	--dtb "$tmp/patched.dtb" --pagesize 4096 --base 0 \
	--kernel_offset 0x8000 --ramdisk_offset 0x01000000 \
	--second_offset 0 --tags_offset 0x100 --dtb_offset 0x01f00000 \
	--board '' --cmdline "$CMDLINE" -o "$tmp/candidate.img"

[[ "$(stat -c %s "$tmp/candidate.img")" == "78012416" ]]
python3 - "$BASE" "$tmp/candidate.img" "$BOOT_HEADER_ID_FIRST" \
	"$BOOT_DTB_OFFSET" "$BUILTIN_DTB_OFFSET" "$APPENDED_DTB_OFFSET" \
	"$DTB_DIFF_OFFSET" <<'PY'
import sys

old = open(sys.argv[1], "rb").read()
new = open(sys.argv[2], "rb").read()
header_first, boot_dtb, builtin, appended, dtb_pos = map(int, sys.argv[3:])
diff = [(i + 1, a, b) for i, (a, b) in enumerate(zip(old, new)) if a != b]
header = diff[:20]
payload = diff[20:]
header_positions = list(range(header_first, header_first + 20))
payload_positions = [
    4096 + builtin + dtb_pos,
    4096 + appended + dtb_pos,
    boot_dtb + dtb_pos,
]
if (
    len(old) != len(new)
    or [pos for pos, _, _ in header] != header_positions
    or [pos for pos, _, _ in payload] != payload_positions
    or any((a, b) != (0x80, 0x30) for _, a, b in payload)
):
    raise SystemExit(f"unexpected boot-image delta: lengths={len(old)}/{len(new)} diff={diff}")
print("boot header ID digest delta:", header)
print("boot payload delta:", payload)
PY

unpack_bootimg --boot_img "$tmp/candidate.img" --out "$tmp/verify" \
	--format=mkbootimg >"$tmp/verify/mkbootimg-args.txt"
cmp "$tmp/patched.kernel" "$tmp/verify/kernel"
cmp "$tmp/base/ramdisk" "$tmp/verify/ramdisk"
cmp "$tmp/patched.dtb" "$tmp/verify/dtb"
grep -Fq -- "--header_version 2" "$tmp/verify/mkbootimg-args.txt"
grep -Fq -- "--cmdline '$CMDLINE'" "$tmp/verify/mkbootimg-args.txt"

install -m 0644 "$tmp/candidate.img" "$OUT"
install -m 0644 "$tmp/patched.dtb" "$OUT_DTB"
(
	cd "$PROJECT"
	sha256sum \
		"$OUT_REL" \
		"$DTB_REL" \
		"$BASE_REL" \
		"patches/stability-ipa-imem-c1/build.sh" \
		"patches/stability-ipa-imem-c1/README.md"
) >"$HERE/out/MANIFEST.sha256"

sha256sum "$OUT" "$OUT_DTB" "$HERE/out/MANIFEST.sha256"
printf 'stability IPA IMEM candidate: %s\n' "$OUT"
