#!/usr/bin/env python3
"""Point IPA modem-tables at Aurora's IMEM window inside a boot image.

Aurora pineapple-ipa.dtsi maps IPA AP SMMU:
  qcom,additional-mapping = <0x14683000 0x14683000 0x2000>
Mainline only identity-maps the DT sram reg. Stock Cerro images use
modem-tables@8000 reg <0x8000 0x2000> (0x14688000), which leaves
IOVA 0x14684080 unmapped and the modem hits a fatal IPA IRQ.

This rewrites every FDT in the boot image whose modem-tables reg is
<0x8000 0x2000> to <0x3000 0x2000>. Node name stays modem-tables@8000.
"""

from __future__ import annotations

import struct
import sys

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9
MAGIC = b"\xd0\x0d\xfe\xed"


def align4(n: int) -> int:
    return (n + 3) & ~3


def patch_dtb(buf: bytearray, off: int) -> int:
    if buf[off : off + 4] != MAGIC:
        return 0
    if off + 40 > len(buf):
        return 0
    (
        totalsize,
        off_struct,
        off_strings,
        _off_rsv,
        version,
        _last,
        _cpu,
        size_strings,
        size_struct,
    ) = struct.unpack_from(">IIIIIIIII", buf, off + 4)
    if version < 17 or totalsize < 64 or off + totalsize > len(buf):
        return 0
    if off_strings + size_strings > totalsize or off_struct + size_struct > totalsize:
        return 0
    strings = bytes(buf[off + off_strings : off + off_strings + size_strings])
    p = off + off_struct
    end = off + off_struct + size_struct
    stack = [""]
    changed = 0
    while p + 4 <= end:
        token = struct.unpack_from(">I", buf, p)[0]
        p += 4
        if token == FDT_BEGIN_NODE:
            start = p
            while p < end and buf[p] != 0:
                p += 1
            name = bytes(buf[start:p]).decode("ascii", "replace")
            p = align4(p + 1)
            stack.append(name)
        elif token == FDT_END_NODE:
            if len(stack) > 1:
                stack.pop()
        elif token == FDT_PROP:
            if p + 8 > end:
                break
            length, nameoff = struct.unpack_from(">II", buf, p)
            p += 8
            if nameoff >= len(strings) or p + length > end:
                break
            endname = strings.find(b"\0", nameoff)
            name = strings[nameoff:endname].decode("ascii", "replace")
            node = stack[-1]
            if name == "reg" and node.startswith("modem-tables") and length == 8:
                addr, size = struct.unpack_from(">II", buf, p)
                if addr == 0x8000 and size == 0x2000:
                    struct.pack_into(">I", buf, p, 0x3000)
                    changed += 1
            p = align4(p + length)
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            print(f"walk stop off={off:#x} token={token:#x} node={stack[-1]!r}")
            break
    return changed


def patch_image(path: str) -> int:
    with open(path, "r+b") as fh:
        data = bytearray(fh.read())
        total = 0
        start = 0
        blobs = 0
        while True:
            off = data.find(MAGIC, start)
            if off < 0:
                break
            n = patch_dtb(data, off)
            if n:
                blobs += 1
                total += n
                print(f"patched dtb off={off:#x} props={n}")
            start = off + 4
        if total == 0:
            print("no modem-tables reg <0x8000 0x2000> found")
            return 1
        fh.seek(0)
        fh.write(data)
        fh.flush()
        print(f"wrote {total} props in {blobs} dtbs")
        return 0


if __name__ == "__main__":
    sys.exit(patch_image(sys.argv[1] if len(sys.argv) > 1 else "/tmp/boot_b.img"))
