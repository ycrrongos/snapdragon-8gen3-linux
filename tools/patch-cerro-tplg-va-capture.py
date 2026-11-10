#!/usr/bin/env python3
"""Retarget Cerro MultiMedia2 capture from Tertiary MI2S to VA_CODEC_DMA_TX_0.

The stock CERRO topology is a LEMANS-EVK borrow: capture BE is TERTIARY_MI2S_TX.
Handset mics on cerro are LPASS DMICs into va_macro (Aurora/stock dmic01/23),
so the FE must use VA_CODEC_DMA_TX_0 like X13s/QRD VA graphs.

Binary surgery (fixed 14908-byte s5fz topology):
  - rename Tertiary MI2S Capture / TERTIARY_MI2S_TX strings
  - MODULE_ID 0x0700100b (I2S) -> 0x07001024 (CODEC_DMA)  [from X13s]
  - HW_IF_TYPE 6 (MI2S) -> 3 (CODEC_DMA)                    [from X13s]
  - HW_IF_IDX  2 -> 1                                        [from X13s]
  - AR_TKN_DAI_INDEX 21 (TERTIARY_MI2S_TX) -> 110 (VA_CODEC_DMA_TX_0)
    (without this, ASoC opens graph 110 but tplg only registered id 21:
     "No graph found with id 110")
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

EXPECTED_SIZE = 14908

# Widget / mixer string sites (null-padded fixed fields)
TERTIARY_CAPTURE_NAME_OFF = 6112
TERTIARY_MIXER_ENUM_OFF = 6932
# Duplicate string table near end of file
TERTIARY_CAPTURE_NAME_OFF_2 = 14300
TERTIARY_MIXER_ENUM_OFF_2 = 14520

# HW EP module tokens inside Tertiary MI2S Capture graph
MODULE_ID_OFF = 6316  # u32 token 0xc8, then u32 value LE 0x0700100b
HW_IF_TYPE_OFF = 6372  # u32 token 0xfb (=251), then u32 value
HW_IF_IDX_OFF = 6380  # u32 token 0xfa (=250), then u32 value

# AR_TKN_DAI_INDEX (=1) sites whose value is still TERTIARY_MI2S_TX (21)
DAI_INDEX_TOKEN_OFFS = (6212, 6556, 7304)
TERTIARY_DAI_ID = 21
VA_CODEC_DMA_TX_0_DAI_ID = 110


def _replace_padded(data: bytearray, offset: int, old: bytes, new: bytes, field: int) -> None:
    cur = bytes(data[offset : offset + field])
    if not cur.startswith(old):
        raise SystemExit(
            f"@{offset}: expected {old!r}..., got {cur.split(b'\\0', 1)[0]!r}"
        )
    if len(new) >= field:
        raise SystemExit(f"@{offset}: new name too long for {field}-byte field")
    data[offset : offset + field] = new.ljust(field, b"\0")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = bytearray(args.input.read_bytes())
    if len(data) != EXPECTED_SIZE:
        raise SystemExit(f"unexpected topology size: {len(data)}")

    # MODULE_ID token/value
    tok, val = struct.unpack_from("<II", data, MODULE_ID_OFF)
    if tok != 0xC8 or val != 0x0700100B:
        raise SystemExit(f"unexpected MODULE_ID @{MODULE_ID_OFF}: {tok:#x}/{val:#x}")
    struct.pack_into("<I", data, MODULE_ID_OFF + 4, 0x07001024)

    tok, val = struct.unpack_from("<II", data, HW_IF_TYPE_OFF)
    if tok != 0xFB or val != 6:
        raise SystemExit(f"unexpected HW_IF_TYPE @{HW_IF_TYPE_OFF}: {tok:#x}/{val}")
    struct.pack_into("<I", data, HW_IF_TYPE_OFF + 4, 3)

    tok, val = struct.unpack_from("<II", data, HW_IF_IDX_OFF)
    if tok != 0xFA or val != 2:
        raise SystemExit(f"unexpected HW_IF_IDX @{HW_IF_IDX_OFF}: {tok:#x}/{val}")
    struct.pack_into("<I", data, HW_IF_IDX_OFF + 4, 1)

    for off in DAI_INDEX_TOKEN_OFFS:
        tok, val = struct.unpack_from("<II", data, off)
        if tok != 1 or val != TERTIARY_DAI_ID:
            raise SystemExit(
                f"unexpected DAI_INDEX @{off}: token={tok} value={val} "
                f"(want token=1 value={TERTIARY_DAI_ID})"
            )
        struct.pack_into("<I", data, off + 4, VA_CODEC_DMA_TX_0_DAI_ID)

    _replace_padded(
        data,
        TERTIARY_CAPTURE_NAME_OFF,
        b"Tertiary MI2S Capture",
        b"VA_CODEC_DMA_TX_0 Capture",
        44,
    )
    _replace_padded(
        data,
        TERTIARY_MIXER_ENUM_OFF,
        b"TERTIARY_MI2S_TX",
        b"VA_CODEC_DMA_TX_0",
        32,
    )
    _replace_padded(
        data,
        TERTIARY_CAPTURE_NAME_OFF_2,
        b"Tertiary MI2S Capture",
        b"VA_CODEC_DMA_TX_0 Capture",
        44,
    )
    _replace_padded(
        data,
        TERTIARY_MIXER_ENUM_OFF_2,
        b"TERTIARY_MI2S_TX",
        b"VA_CODEC_DMA_TX_0",
        32,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"VA capture retarget: {args.output} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
