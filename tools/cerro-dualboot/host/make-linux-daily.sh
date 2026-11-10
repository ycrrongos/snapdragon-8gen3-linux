#!/usr/bin/env bash
# Build Cerro linux-daily.img (notes/cerro-daily-boot-fix.md).
#
# Correct behaviour (keep ACM):
#   - setup_acm still runs → USB gadget ACM+ECM present with or without host
#   - ttyGS0 *writes* only when cmdline has cerro_acm_log (opt-in)
#   - DTB often still has ignore_loglevel (ABL ignores boot.img cmdline); do NOT
#     key CONSOLE_ON off ignore_loglevel or daily will still block without USB
#
# Method: clone src boot → in-place replace embedded /init (pad to same size) →
# recompress into same gzip slot → quiet header cmdline; ramdisk_size stays 127.
#
# Usage:
#   tools/cerro-dualboot/host/make-linux-daily.sh [src.img] [out.img]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="${1:-$ROOT/build/dualboot/boot-live-b.img}"
OUT="${2:-$ROOT/build/dualboot/linux-daily.img}"
INIT_SRC="${CERRO_DAILY_INIT:-$ROOT/build/dualboot/daily-init-work/init-patched}"
EMBED_OFF="${CERRO_INITRAMFS_OFF:-37811712}"
STAMP=$(date +%Y%m%d-%H%M)
LABEL="${CERRO_DAILY_LABEL:-daily-$STAMP}"
ADD_DIR="${CERRO_DAILY_ADD_DIR:-}"
SLOT_BYTES="${CERRO_INITRAMFS_SLOT_BYTES:-0}"
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad label: $LABEL" >&2; exit 2; }

[[ -f "$SRC" && -f "$INIT_SRC" ]] || { echo "missing src/init" >&2; exit 2; }
grep -q cerro_acm_log "$INIT_SRC" || { echo "init must gate on cerro_acm_log" >&2; exit 2; }
grep -q setup_acm "$INIT_SRC" || { echo "init must keep setup_acm" >&2; exit 2; }

python3 - "$SRC" "$OUT" "$INIT_SRC" "$EMBED_OFF" "$LABEL" "$ADD_DIR" "$SLOT_BYTES" <<'PY'
import binascii, struct, sys, zlib, subprocess, gzip, io, stat
from pathlib import Path

src, out, init_path, off_s, label, add_dir, slot_bytes = sys.argv[1:8]
off = int(off_s)
work = Path("/tmp/cerro-make-daily-inplace")
work.mkdir(exist_ok=True)
subprocess.check_call(
    ["unpack_bootimg", "--boot_img", src, "--out", str(work / "u")],
    stdout=subprocess.DEVNULL,
)
k = bytearray((work / "u" / "kernel").read_bytes())
assert k[off : off + 2] == b"\x1f\x8b"

def gzip_member(buf, off):
    flags = buf[off + 3]
    pos = off + 10
    if flags & 4:
        xlen = struct.unpack_from("<H", buf, pos)[0]
        pos += 2 + xlen
    if flags & 8:
        while buf[pos] != 0:
            pos += 1
        pos += 1
    if flags & 16:
        while buf[pos] != 0:
            pos += 1
        pos += 1
    if flags & 2:
        pos += 2
    d = zlib.decompressobj(-zlib.MAX_WBITS)
    outb = bytearray()
    i = pos
    while i < len(buf):
        chunk = bytes(buf[i : i + 65536])
        outb.extend(d.decompress(chunk))
        i += len(chunk)
        if d.unused_data:
            unused_off = i - len(d.unused_data)
            return bytes(outb), (unused_off + 8) - off
    raise SystemExit("gzip member has no end")

raw, consumed = gzip_member(k, off)
if int(slot_bytes):
    reserved = int(slot_bytes)
    if reserved < consumed or off + reserved > len(k):
        raise SystemExit("invalid declared initramfs slot size")
    if any(k[off + consumed:off + reserved]):
        raise SystemExit("declared slot extends beyond zero padding")
    consumed = reserved
print(f"cpio raw={len(raw)} gzip_slot={consumed}")

def find_init(cpio: bytes):
    pos = 0
    while pos + 110 <= len(cpio):
        mag = cpio[pos : pos + 6]
        if mag not in (b"070701", b"070702"):
            if cpio[pos : pos + 1] == b"\x00":
                pos += 1
                continue
            break
        hdr = cpio[pos : pos + 110]
        namesize = int(hdr[94:102], 16)
        filesize = int(hdr[54:62], 16)
        name_start = pos + 110
        name = cpio[name_start : name_start + namesize - 1]
        name_pad_end = (name_start + namesize + 3) & ~3
        data_start = name_pad_end
        data_end = data_start + filesize
        data_pad_end = (data_end + 3) & ~3
        if name in (b"init", b"./init"):
            return data_start, filesize
        if name == b"TRAILER!!!":
            break
        pos = data_pad_end
    raise SystemExit("init not found in cpio")

dstart, fsz = find_init(raw)
new = Path(init_path).read_bytes()
assert b"cerro_acm_log" in new and b"setup_acm" in new
if len(new) > fsz:
    raise SystemExit(f"new init {len(new)} > old slot {fsz}")
print(f"init replace {fsz} <- {len(new)} (pad {fsz - len(new)})")
raw2 = bytearray(raw)
raw2[dstart : dstart + fsz] = new + b"\n" * (fsz - len(new))

if add_dir:
    # Append a scoped early-DRM payload before the original trailer. Preserve
    # all existing cpio entries and metadata; never replace /lib or its symlink.
    root = Path(add_dir)
    if not root.is_dir():
        raise SystemExit("missing early-DRM payload directory")
    names, max_ino, pos = set(), 0, 0
    while pos + 110 <= len(raw2):
        hdr = raw2[pos:pos + 110]
        if hdr[:6] != b"070701":
            raise SystemExit("invalid newc header while finding trailer")
        fields = [int(hdr[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        size, nlen = fields[6], fields[11]
        name = bytes(raw2[pos + 110:pos + 110 + nlen - 1]).decode()
        if name == "TRAILER!!!":
            break
        names.add(name.removeprefix("./"))
        max_ino = max(max_ino, fields[0])
        start = (pos + 110 + nlen + 3) & ~3
        pos = (start + size + 3) & ~3
    else:
        raise SystemExit("cpio trailer missing")

    additions = bytearray()
    for item in sorted(root.rglob("*")):
        name = item.relative_to(root).as_posix()
        if not (name == "cerro-early-drm" or name.startswith("cerro-early-drm/")):
            raise SystemExit(f"unexpected payload path: {name}")
        if name in names or item.is_symlink():
            raise SystemExit(f"payload collision or symlink: {name}")
        mode = item.stat().st_mode
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SystemExit(f"unsupported payload file type: {name}")
        data = item.read_bytes() if item.is_file() else b""
        max_ino += 1
        enc_name = name.encode() + b"\x00"
        values = (max_ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(enc_name), 0)
        record = b"070701" + b"".join(f"{v:08x}".encode() for v in values) + enc_name
        record += b"\x00" * (-len(record) % 4)
        record += data
        record += b"\x00" * (-len(record) % 4)
        additions.extend(record)
        print(f"cpio add {name} bytes={len(data)}")
    if not additions:
        raise SystemExit("empty early-DRM payload")
    raw2 = raw2[:pos] + additions + raw2[pos:]

bio = io.BytesIO()
with gzip.GzipFile(fileobj=bio, mode="wb", compresslevel=9, mtime=0) as g:
    g.write(raw2)
new_gz = bio.getvalue()
if len(new_gz) > consumed:
    comp = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    body = comp.compress(bytes(raw2)) + comp.flush()
    crc = binascii.crc32(bytes(raw2)) & 0xFFFFFFFF
    isize = len(raw2) & 0xFFFFFFFF
    new_gz = (
        b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03"
        + body
        + struct.pack("<II", crc, isize)
    )
print(f"new gzip={len(new_gz)} max={consumed}")
if len(new_gz) > consumed:
    raise SystemExit("gzip does not fit")
k[off : off + consumed] = new_gz + b"\x00" * (consumed - len(new_gz))

img = bytearray(Path(src).read_bytes())
needle = bytes(k[100000:100064])
idx = img.find(needle)
if idx < 0:
    raise SystemExit("kernel not found in boot.img")
koff = idx - 100000
ksize = struct.unpack_from("<I", img, 8)[0]
assert len(k) == ksize
img[koff : koff + ksize] = k

# Android boot v2 has a 512-byte field and a 1024-byte continuation after ID.
# Read both so a marker in the continuation cannot override the new label.
cmdline = (img[64:576] + img[608:1632]).split(b"\x00", 1)[0].decode()
parts = []
for p in cmdline.split():
    if p == "ignore_loglevel" or p.startswith("earlycon="):
        continue
    parts.append(p)
if "quiet" not in parts:
    parts.insert(0, "quiet")
if not any(x.startswith("loglevel=") for x in parts):
    parts.insert(1, "loglevel=3")
# Do NOT mask serial-getty@ttyGS0 — ACM login is the debug port. Boot speed is
# protected by CONSOLE_ON=cerro_acm_log only (no ttyGS0 writes without a reader).
parts = [p for p in parts if not p.startswith("cerro_boot=")
         and not p.startswith("systemd.mask=serial-getty@ttyGS0")
         and not p.startswith("console=ttyGS0")]
parts.append(f"cerro_boot={label}")
enc = " ".join(parts).encode()
assert len(enc) < 1536
packed = enc + b"\x00" * (1536 - len(enc))
img[64:576] = packed[:512]
img[608:1632] = packed[512:]
Path(out).write_bytes(img)
print(f"wrote {out} ({len(img)})")
print("cmdline:", enc.decode()[:180])
PY

sha256sum "$OUT" | tee "${OUT}.sha256"
cp -a "$OUT" "${OUT%.img}-${STAMP}.img"
cp -a "${OUT}.sha256" "${OUT%.img}-${STAMP}.img.sha256"
echo "OK: $OUT (ACM kept; CONSOLE_ON=cerro_acm_log only)"
