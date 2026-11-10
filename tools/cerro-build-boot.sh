#!/usr/bin/env bash
# Cerro Linux boot.img — the only supported full rebuild entry.
# Scheme E: guard → builtin DTB → Image → mkbootimg from a proven header → pad 96MiB.
#
#   tools/cerro-build-boot.sh <label>
#   REF_BOOT=build/dualboot/linux-debug-rescue.img   (default)
#   JOBS=10
#
# Do not hand-roll mkbootimg. Init-only splices stay in notes/cerro-daily-boot-fix.md;
# this script is for a new Image/DTB (display, DTS, scheme E).
set -euo pipefail

LABEL=${1:?usage: tools/cerro-build-boot.sh <label>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/build/linux-7.2"
REF="${REF_BOOT:-$ROOT/build/dualboot/linux-debug-rescue.img}"
OUT="$ROOT/build/dualboot/linux-${LABEL}.img"
JOBS="${JOBS:-$(nproc)}"
PAD=100663296
DTB_REL=arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb
BUILTIN_DTB=arch/arm64/kernel/sm8650-nubia-cerro.dtb

[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad label: $LABEL" >&2; exit 2; }
[[ -f "$REF" ]] || { echo "missing REF_BOOT=$REF" >&2; exit 2; }
[[ -x "$K" || -d "$K" ]] || { echo "missing kernel tree $K" >&2; exit 2; }
command -v mkbootimg >/dev/null
command -v unpack_bootimg >/dev/null

echo "== tree $(git -C "$K" rev-parse --short HEAD) =="
echo "== builtin DTB + Image (JOBS=$JOBS) =="
# Empty-but-set stops scripts/setlocalversion from appending '+' past the tag.
# CONFIG_LOCALVERSION in .config supplies the real suffix (here -dirty).
export LOCALVERSION="${LOCALVERSION-}"
make -C "$K" ARCH=arm64 LLVM=1 -j"$JOBS" dtbs
test -f "$K/$DTB_REL"
cp -f "$K/$DTB_REL" "$K/$BUILTIN_DTB"
rm -f "$K/arch/arm64/kernel/sm8650-nubia-cerro.dtb.o" \
      "$K/arch/arm64/kernel/.sm8650-nubia-cerro.dtb.o"
make -C "$K" ARCH=arm64 LLVM=1 -j"$JOBS" Image
test -f "$K/arch/arm64/boot/Image"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
unpack_bootimg --boot_img "$REF" --out "$STAGING/ref" >/dev/null
# One line, cmdline in single quotes. Do not word-split it.
MK_LINE=$(unpack_bootimg --boot_img "$REF" --format=mkbootimg --out "$STAGING/ref")
CMDLINE=$(python3 -c 'import re,sys; t=sys.argv[1]; m=re.search(r"--cmdline '"'"'(.*)'"'"'\s*$", t); print(m.group(1) if m else "")' "$MK_LINE")
[[ -n "$CMDLINE" ]] || { echo "failed to parse cmdline from $REF" >&2; exit 2; }
# Sanitize REF pollution: never mask ACM getty; never bind console to ttyGS0
# (write blocks forever with no host → daily boot hang). Printk stays on
# tty0/ttyMSM0; ACM+ECM still come from embedded init setup_acm.
CMDLINE=$(python3 -c '
import sys
c, label = sys.argv[1], sys.argv[2]
parts = []
for p in c.split():
    if p.startswith("systemd.mask=serial-getty@ttyGS0"):
        continue
    if p.startswith("console=ttyGS0"):
        continue
    if p.startswith("cerro_boot="):
        continue
    parts.append(p)
parts.append(f"cerro_boot={label}")
print(" ".join(parts))
' "$CMDLINE" "$LABEL")
echo "== cmdline sanitized (ACM getty unmasked, cerro_boot=$LABEL) =="

# ABL on this phone reads the DTB appended at the Image header's image_size.
# objcopy strips the trailing zeros, so a bare Image is short and never boots.
# Rescue and cam-c1 both pad with zeros to image_size, then append the DTB.
python3 - "$K/arch/arm64/boot/Image" "$K/$DTB_REL" "$STAGING/kernel" <<'PY'
import struct, sys
from pathlib import Path
image, dtb, out = map(Path, sys.argv[1:])
blob = image.read_bytes()
dtb_bytes = dtb.read_bytes()
image_size = struct.unpack_from("<Q", blob, 16)[0]
if image_size < len(blob):
    raise SystemExit(f"image_size {image_size} < Image file {len(blob)}")
if not dtb_bytes.startswith(bytes.fromhex("d00dfeed")):
    raise SystemExit("DTB magic missing")
padded = blob + bytes(image_size - len(blob)) + dtb_bytes
out.write_bytes(padded)
print(f"kernel payload {len(blob)} -> pad {image_size} + dtb {len(dtb_bytes)} = {len(padded)}")
PY

echo "== mkbootimg from $(basename "$REF") header =="
mkbootimg \
  --header_version 2 \
  --os_version 16.0.0 \
  --os_patch_level 2026-07 \
  --kernel "$STAGING/kernel" \
  --ramdisk "$STAGING/ref/ramdisk" \
  --dtb "$K/$DTB_REL" \
  --pagesize 4096 \
  --base 0x00000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00000000 \
  --tags_offset 0x00000100 \
  --dtb_offset 0x01f00000 \
  --cmdline "$CMDLINE" \
  --output "$STAGING/boot.img"
python3 - "$STAGING/boot.img" "$PAD" <<'PY'
import pathlib, sys
p, pad = pathlib.Path(sys.argv[1]), int(sys.argv[2])
data = p.read_bytes()
if len(data) > pad:
    raise SystemExit(f"image {len(data)} > pad {pad}")
p.write_bytes(data + bytes(pad - len(data)))
print(f"padded {len(data)} -> {pad}")
PY
install -m 0644 "$STAGING/boot.img" "$OUT"
SHA=$(sha256sum "$OUT" | awk '{print $1}')
TREE=$(git -C "$K" rev-parse HEAD)
{
  echo "label=$LABEL"
  echo "out=$OUT"
  echo "sha256=$SHA"
  echo "tree=$TREE"
  echo "ref=$REF"
  echo "bytes=$PAD"
} | tee "$OUT.meta"
echo "BUILT $OUT"
echo "$SHA"
