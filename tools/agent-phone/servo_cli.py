#!/usr/bin/env python3
"""Serial CLI for agent-phone servos (ESP32-S3 / STM32 / USB-UART) — no HTTP.

Prefer hand serial by-id; never open the phone's CDC ACM (nubia / 1d6b).
Override with --port or SERVO_PORT.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

import serial

BAUD = 115200
DEFAULT_HOLD_S = 12.0

# Higher = preferred. Skip phone gadget / debug ACM.
_PORT_SCORE = (
    ("espressif", 100),
    ("usb_jtag_serial", 100),
    ("dfrobot", 95),
    ("firebeetle", 95),
    ("3343", 95),  # DFRobot USB VID on some FireBeetle CDC builds
    ("stmicroelectronics", 90),
    ("stm32", 90),
    ("maple", 85),
    ("usb_single_serial", 70),  # CH340/CH910 often on STM32 USB-UART
    ("1a86", 65),
)


def _score_by_id(name: str) -> int:
    low = name.lower()
    if "nubia" in low or "cerro" in low or "gadget" in low:
        return -1
    best = 0
    for key, score in _PORT_SCORE:
        if key in low:
            best = max(best, score)
    return best


def resolve_port(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    env = os.environ.get("SERVO_PORT")
    if env:
        return env
    by_id = Path("/dev/serial/by-id")
    if by_id.is_dir():
        ranked: list[tuple[int, Path]] = []
        for path in by_id.iterdir():
            sc = _score_by_id(path.name)
            if sc > 0:
                ranked.append((sc, path))
        if ranked:
            ranked.sort(key=lambda t: (-t[0], t[1].name))
            return str(ranked[0][1])
    raise SystemExit(
        "ERROR: no hand serial (by-id). Plug ESP32/STM32 UART, or set SERVO_PORT=..."
    )


def open_ser(port: str) -> serial.Serial:
    ser = serial.Serial(port, BAUD, timeout=1.0, write_timeout=2.0)
    time.sleep(0.4)
    ser.reset_input_buffer()
    # Board may already be up; don't wait long for READY
    deadline = time.time() + 1.5
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="replace").strip()
        if "READY" in line:
            break
    return ser


def send(ser: serial.Serial, cmd: str, timeout: float = 2.5) -> str:
    ser.reset_input_buffer()
    ser.write((cmd.strip() + "\n").encode("ascii"))
    ser.flush()
    deadline = time.time() + timeout
    while time.time() < deadline:
        raw = ser.readline().decode("utf-8", errors="replace").strip()
        if not raw:
            continue
        if raw.startswith("OK") or raw.startswith("ERR"):
            return raw
    raise TimeoutError(f"no reply for {cmd!r}")


def parse_angles(reply: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for key in (
        "U",
        "D",
        "P",
        "RESTU",
        "RESTD",
        "RESTP",
        "PRESSU",
        "PRESSD",
        "PRESSP",
    ):
        m = re.search(rf"\b{key}=(\d+)", reply)
        if m:
            out[key] = int(m.group(1))
    return out


def cmd_ping(ser: serial.Serial) -> None:
    print(send(ser, "PING"))


def cmd_angles(ser: serial.Serial) -> None:
    print(send(ser, "G"))


def cmd_reset(ser: serial.Serial) -> None:
    print(send(ser, "G"))
    a = parse_angles(send(ser, "G"))
    # Prefer REST* if known, else current
    ru = a.get("RESTU", a.get("U", 90))
    rd = a.get("RESTD", a.get("D", 90))
    rp = a.get("RESTP", a.get("P", 90))
    print(send(ser, f"SA:{ru},{rd},{rp}"))


def cmd_tap(ser: serial.Serial, which: str, hold_ms: int) -> None:
    a = parse_angles(send(ser, "G"))
    map_press = {"volup": "PRESSU", "voldown": "PRESSD", "power": "PRESSP"}
    map_rest = {"volup": "RESTU", "voldown": "RESTD", "power": "RESTP"}
    map_cur = {"volup": "U", "voldown": "D", "power": "P"}
    map_set = {"volup": "SU", "voldown": "SD", "power": "SP"}
    press = a.get(map_press[which], {"volup": 60, "voldown": 120, "power": 120}[which])
    rest = a.get(map_rest[which], a.get(map_cur[which], 90))
    prefix = map_set[which]
    print(send(ser, f"{prefix}:{press}"))
    time.sleep(hold_ms / 1000.0)
    print(send(ser, f"{prefix}:{rest}"))


def _usb_has_9008() -> bool:
    import subprocess

    try:
        out = subprocess.check_output(["lsusb"], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return "05c6:9008" in out


def _usb_summary() -> str:
    import subprocess

    try:
        out = subprocess.check_output(["lsusb"], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "(lsusb failed)"
    hits = [
        ln
        for ln in out.splitlines()
        if any(x in ln for x in ("9008", "d00d", "0104", "0112", "4e11", "4ee7"))
    ]
    return "; ".join(hits) if hits else "(no phone usb)"


def cmd_hold_edl(
    ser: serial.Serial,
    seconds: float,
    *,
    until_9008: bool = True,
    min_hold_s: float = 8.0,
) -> int:
    """Power + Vol+ + Vol- for EDL.

    Default: keep pressed until ``05c6:9008`` appears (or ``seconds`` timeout),
    then release. ``min_hold_s`` avoids releasing on a stale/transient 9008.
    """
    a = parse_angles(send(ser, "G"))
    pu = a.get("PRESSU", 60)
    pd = a.get("PRESSD", 120)
    pp = a.get("PRESSP", 120)
    ru = a.get("RESTU", 90)
    rd = a.get("RESTD", 90)
    rp = a.get("RESTP", 90)
    mode = f"until-9008 (max {seconds:.0f}s, min {min_hold_s:.0f}s)" if until_9008 else f"{seconds:.1f}s fixed"
    print(f"hold-edl press SA:{pu},{pd},{pp} {mode}", flush=True)
    print(send(ser, f"SA:{pu},{pd},{pp}"), flush=True)
    t0 = time.time()
    got_9008 = False
    try:
        while True:
            elapsed = time.time() - t0
            if until_9008:
                if elapsed >= min_hold_s and _usb_has_9008():
                    got_9008 = True
                    print(f"  … {elapsed:.0f}s — 9008 seen, releasing", flush=True)
                    break
                if elapsed >= seconds:
                    print(
                        f"  … TIMEOUT {seconds:.0f}s without 9008; usb={_usb_summary()}",
                        flush=True,
                    )
                    break
            else:
                if elapsed >= seconds:
                    break
            time.sleep(1.0)
            print(f"  … {elapsed:.0f}s usb={_usb_summary()}", flush=True)
    finally:
        # Always release, even on interrupt.
        print(send(ser, f"SA:{ru},{rd},{rp}"), flush=True)
        print("hold-edl released", flush=True)
    return 0 if (got_9008 or not until_9008) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", default=None, help="override serial port")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("angles")
    sub.add_parser("reset")

    p_tap = sub.add_parser("tap")
    p_tap.add_argument("button", choices=("volup", "voldown", "power"))
    p_tap.add_argument("--ms", type=int, default=400)

    p_hold = sub.add_parser("hold-edl", help="hold power+vol± until 9008 (or timeout)")
    p_hold.add_argument(
        "--seconds",
        type=float,
        default=60.0,
        help="max hold seconds while waiting for 9008 (default 60)",
    )
    p_hold.add_argument(
        "--min-hold",
        type=float,
        default=8.0,
        help="minimum press time before accepting 9008 (default 8)",
    )
    p_hold.add_argument(
        "--fixed-time",
        action="store_true",
        help="old behavior: hold exactly --seconds then release (ignore USB)",
    )

    args = ap.parse_args()
    port = resolve_port(args.port)
    print(f"port={port}", flush=True)
    ser = open_ser(port)
    rc = 0
    try:
        if args.cmd == "ping":
            cmd_ping(ser)
        elif args.cmd == "angles":
            cmd_angles(ser)
        elif args.cmd == "reset":
            cmd_reset(ser)
        elif args.cmd == "tap":
            cmd_tap(ser, args.button, args.ms)
        elif args.cmd == "hold-edl":
            rc = cmd_hold_edl(
                ser,
                args.seconds,
                until_9008=not args.fixed_time,
                min_hold_s=args.min_hold,
            )
        else:
            return 2
    finally:
        ser.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
