#!/usr/bin/env python3
"""Constrained AW88261 register reader/updater for Cerro bring-up.

This intentionally permits only the two known smart-PA addresses on i2c-0.
It uses I2C_SLAVE_FORCE because the kernel codec driver owns the addresses.
"""

from __future__ import annotations

import argparse
import fcntl
import os


I2C_SLAVE_FORCE = 0x0706
ALLOWED_ADDRESSES = {0x34, 0x35}


def number(value: str) -> int:
    return int(value, 0)


def read_register(fd: int, register: int) -> int:
    os.write(fd, bytes((register,)))
    data = os.read(fd, 2)
    if len(data) != 2:
        raise OSError(f"short I2C read: expected 2 bytes, got {len(data)}")
    # aw88261 regmap: 8-bit register address, 16-bit big-endian value.
    return int.from_bytes(data, "big")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("address", type=number)
    parser.add_argument("register", type=number)
    parser.add_argument("--bus", default="/dev/i2c-0")
    parser.add_argument("--mask", type=number, help="bits to update")
    parser.add_argument("--value", type=number, help="new masked value")
    args = parser.parse_args()

    if args.address not in ALLOWED_ADDRESSES:
        parser.error("address must be 0x34 or 0x35")
    if not 0 <= args.register <= 0x80:
        parser.error("register must be in 0x00..0x80")
    if (args.mask is None) != (args.value is None):
        parser.error("--mask and --value must be supplied together")

    fd = os.open(args.bus, os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, args.address)
        old = read_register(fd, args.register)
        if args.mask is None:
            print(f"0x{args.address:02x} reg 0x{args.register:02x} = 0x{old:04x}")
            return 0

        mask = args.mask & 0xFFFF
        new = (old & ~mask) | (args.value & mask)
        os.write(fd, bytes((args.register, new >> 8, new & 0xFF)))
        actual = read_register(fd, args.register)
        print(
            f"0x{args.address:02x} reg 0x{args.register:02x}: "
            f"0x{old:04x} -> 0x{actual:04x} (requested 0x{new:04x})"
        )
        return 0 if actual == new else 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
