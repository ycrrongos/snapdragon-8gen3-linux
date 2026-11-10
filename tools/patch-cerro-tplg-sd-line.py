#!/usr/bin/env python3
"""Patch Cerro PRIMARY_MI2S_RX SD line in the known 14,908-byte topology."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


HW_IF_TYPE_OFFSET = 6028
SD_LINE_TOKEN_OFFSET = 6052


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--line", type=int, choices=(1, 2), required=True,
                        help="Audioreach token value: 1=I2S_SD0, 2=I2S_SD1")
    args = parser.parse_args()

    data = bytearray(args.input.read_bytes())
    if len(data) != 14908:
        raise SystemExit(f"unexpected topology size: {len(data)}")
    if struct.unpack_from("<II", data, HW_IF_TYPE_OFFSET) != (251, 0):
        raise SystemExit("PRIMARY_MI2S HW_IF_TYPE is not the expected LPAIF value")
    token, old_line = struct.unpack_from("<II", data, SD_LINE_TOKEN_OFFSET)
    if token != 256 or old_line not in (1, 2):
        raise SystemExit(f"unexpected SD line tuple: token={token} value={old_line}")

    struct.pack_into("<I", data, SD_LINE_TOKEN_OFFSET + 4, args.line)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"PRIMARY_MI2S SD_LINE_IDX {old_line} -> {args.line}: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
