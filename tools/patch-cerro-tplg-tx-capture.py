#!/usr/bin/env python3
"""Retarget Cerro MultiMedia2 capture to TX_CODEC_DMA_TX_3 (Aurora handset).

Aurora `handset-mic` uses amic1 via tx_macro + SoundWire, BE TX_CODEC_DMA_TX_3
(DTS `wcd-capture-dai-link`). Stock CERRO tplg still has TERTIARY_MI2S_TX.

Binary surgery on the fixed 14908-byte s5fz topology:
  - rename Tertiary MI2S Capture / TERTIARY_MI2S_TX strings
  - MODULE_ID 0x0700100b (I2S) -> 0x07001024 (CODEC_DMA)
  - HW_IF_TYPE 6 (MI2S) -> 1                    [from 21BX TX3]
  - HW_IF_IDX  2 -> 4                           [from 21BX TX3]
  - AR_TKN_DAI_INDEX 21 -> 120 (TX_CODEC_DMA_TX_3)
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

EXPECTED_SIZE = 14908

TERTIARY_CAPTURE_NAME_OFF = 6112
TERTIARY_MIXER_ENUM_OFF = 6932
TERTIARY_CAPTURE_NAME_OFF_2 = 14300
TERTIARY_MIXER_ENUM_OFF_2 = 14520

MODULE_ID_OFF = 6316
HW_IF_TYPE_OFF = 6372
HW_IF_IDX_OFF = 6380

DAI_INDEX_TOKEN_OFFS = (6212, 6556, 7304)
TERTIARY_DAI_ID = 21
TX_CODEC_DMA_TX_3_DAI_ID = 120


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

    tok, val = struct.unpack_from("<II", data, MODULE_ID_OFF)
    if tok != 0xC8 or val != 0x0700100B:
        raise SystemExit(f"unexpected MODULE_ID @{MODULE_ID_OFF}: {tok:#x}/{val:#x}")
    struct.pack_into("<I", data, MODULE_ID_OFF + 4, 0x07001024)

    tok, val = struct.unpack_from("<II", data, HW_IF_TYPE_OFF)
    if tok != 0xFB or val != 6:
        raise SystemExit(f"unexpected HW_IF_TYPE @{HW_IF_TYPE_OFF}: {tok:#x}/{val}")
    struct.pack_into("<I", data, HW_IF_TYPE_OFF + 4, 1)

    tok, val = struct.unpack_from("<II", data, HW_IF_IDX_OFF)
    if tok != 0xFA or val != 2:
        raise SystemExit(f"unexpected HW_IF_IDX @{HW_IF_IDX_OFF}: {tok:#x}/{val}")
    struct.pack_into("<I", data, HW_IF_IDX_OFF + 4, 4)

    for off in DAI_INDEX_TOKEN_OFFS:
        tok, val = struct.unpack_from("<II", data, off)
        if tok != 1 or val != TERTIARY_DAI_ID:
            raise SystemExit(
                f"unexpected DAI_INDEX @{off}: token={tok} value={val}"
            )
        struct.pack_into("<I", data, off + 4, TX_CODEC_DMA_TX_3_DAI_ID)

    _replace_padded(
        data,
        TERTIARY_CAPTURE_NAME_OFF,
        b"Tertiary MI2S Capture",
        b"TX_CODEC_DMA_TX_3 Capture",
        44,
    )
    _replace_padded(
        data,
        TERTIARY_MIXER_ENUM_OFF,
        b"TERTIARY_MI2S_TX",
        b"TX_CODEC_DMA_TX_3",
        32,
    )
    _replace_padded(
        data,
        TERTIARY_CAPTURE_NAME_OFF_2,
        b"Tertiary MI2S Capture",
        b"TX_CODEC_DMA_TX_3 Capture",
        44,
    )
    _replace_padded(
        data,
        TERTIARY_MIXER_ENUM_OFF_2,
        b"TERTIARY_MI2S_TX",
        b"TX_CODEC_DMA_TX_3",
        32,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"TX capture retarget: {args.output} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
