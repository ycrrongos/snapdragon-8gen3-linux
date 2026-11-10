#!/usr/bin/env python3
"""Run one command through the Cerro Linux USB serial console.

The phone and the ESP32 servo are both CDC ACM devices.  Select the phone by
its stable USB by-id name instead of guessing /dev/ttyACM<N>.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shlex
import sys
import time

import serial
from cerro_debug_credentials import defaults, password_or_prompt


ANSI_RE = re.compile(rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
LOGIN_RE = re.compile(rb"(?:^|\r?\n)[^\r\n]*login:\s*$", re.IGNORECASE)
# Debian/PAM localizes the console prompt when zh_CN is active.  Match both
# the English prompt and UTF-8 Chinese "密码：" (full-width or ASCII colon).
PASSWORD_RE = re.compile(
    rb"(?:Password:|\xe5\xaf\x86\xe7\xa0\x81(?:\xef\xbc\x9a|:))\s*$",
    re.IGNORECASE,
)
PROMPT_RE = re.compile(rb"(?:^|\r?\n)[^\r\n]*[$#]\s*$")


def clean(data: bytes) -> bytes:
    return ANSI_RE.sub(b"", data).replace(b"\r", b"")


def read_until(ser: serial.Serial, patterns: tuple[re.Pattern[bytes], ...], timeout: float) -> tuple[bytes, int | None]:
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf.extend(chunk)
            visible = clean(bytes(buf))
            for index, pattern in enumerate(patterns):
                if pattern.search(visible):
                    return bytes(buf), index
    return bytes(buf), None


def choose_port(explicit: str | None) -> str:
    if explicit:
        return explicit
    candidates = sorted(glob.glob("/dev/serial/by-id/*nubia*cerro-debug-if00"))
    if not candidates:
        candidates = sorted(glob.glob("/dev/serial/by-id/*cerro-debug*"))
    candidates = [path for path in candidates if "Espressif" not in path]
    if len(candidates) != 1:
        raise SystemExit(f"expected one Cerro phone ACM by-id device, found: {candidates}")
    return candidates[0]


def login(
    ser: serial.Serial,
    username: str,
    password: str,
    timeout: float,
    *,
    debug: bool = False,
    reset_prompt: bool = False,
) -> bytes:
    transcript = bytearray()
    if reset_prompt:
        # ttyGS0 can retain a Password: prompt from a disconnected client.
        # Abort that stale login transaction before starting a fresh one.
        ser.write(b"\x03\r")
        time.sleep(0.25)
        ser.reset_input_buffer()
    ser.write(b"\r")
    first, state = read_until(ser, (PROMPT_RE, LOGIN_RE, PASSWORD_RE), min(timeout, 8.0))
    transcript.extend(first)

    if state == 0:
        return bytes(transcript)
    if state == 1:
        ser.write(username.encode() + b"\r")
        response, state = read_until(ser, (PASSWORD_RE, PROMPT_RE, LOGIN_RE), timeout)
        transcript.extend(response)
        if state == 1:
            return bytes(transcript)
        if state != 0:
            if debug:
                print(clean(bytes(transcript)).decode("utf-8", "replace"), file=sys.stderr)
            raise RuntimeError("login did not reach password prompt")
    elif state is None:
        # A freshly booted getty can take a moment to redraw its prompt.
        ser.write(b"\r")
        response, state = read_until(ser, (LOGIN_RE, PROMPT_RE, PASSWORD_RE), timeout)
        transcript.extend(response)
        if state == 1:
            return bytes(transcript)
        if state == 0:
            ser.write(username.encode() + b"\r")
            response, state = read_until(ser, (PASSWORD_RE, PROMPT_RE), timeout)
            transcript.extend(response)
            if state == 1:
                return bytes(transcript)
            if state != 0:
                if debug:
                    print(clean(bytes(transcript)).decode("utf-8", "replace"), file=sys.stderr)
                raise RuntimeError("login did not reach password prompt")
        elif state != 2:
            if debug:
                print(clean(bytes(transcript)).decode("utf-8", "replace"), file=sys.stderr)
            raise RuntimeError("serial console produced no login or shell prompt")

    ser.write(password.encode() + b"\r")
    response, state = read_until(ser, (PROMPT_RE, LOGIN_RE, PASSWORD_RE), timeout)
    transcript.extend(response)
    if state != 0:
        if debug:
            print(clean(bytes(transcript)).decode("utf-8", "replace"), file=sys.stderr)
        raise RuntimeError("authentication failed or shell prompt was not reached")
    return bytes(transcript)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", help="shell command to execute on the phone")
    parser.add_argument("--port", help="serial device; defaults to the phone USB by-id path")
    username, password = defaults()
    parser.add_argument("--user", default=username)
    parser.add_argument("--password", default=password)
    parser.add_argument("--login-timeout", type=float, default=20.0)
    parser.add_argument("--command-timeout", type=float, default=60.0)
    parser.add_argument("--debug-login", action="store_true", help="print the console transcript if login fails")
    parser.add_argument("--reset-login", action="store_true", help="abort a stale getty password prompt first")
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="run the command through sudo and answer its prompt without printing the password",
    )
    args = parser.parse_args()
    args.password = password_or_prompt(args.password)

    port = choose_port(args.port)
    print(f"[cerro-acm] port={port} -> {os.path.realpath(port)}", file=sys.stderr)
    with serial.Serial(port, 115200, timeout=0.2, write_timeout=2.0) as ser:
        login(
            ser,
            args.user,
            args.password,
            args.login_timeout,
            debug=args.debug_login,
            reset_prompt=args.reset_login,
        )
        ser.reset_input_buffer()
        marker = f"__CERRO_DONE_{os.getpid()}__"
        sudo_prompt = f"__CERRO_SUDO_{os.getpid()}__"
        # Keep the command and sentinel on one shell input line.  Commands using
        # sudo may allocate a pty and consume a separately queued sentinel line.
        command = args.command
        if args.sudo:
            command = f"sudo -S -p {shlex.quote(sudo_prompt)} sh -c {shlex.quote(command)}"
        payload = f"({command}); _cerro_rc=$?; printf '\\n{marker}:%s\\n' \"$_cerro_rc\"\n"
        ser.write(payload.encode())
        marker_re = re.compile(re.escape(marker.encode()) + rb":([0-9]+)")
        # The terminal echoes the submitted shell line.  Match only the real
        # sudo prompt, which appears alone at the end of a line/buffer, rather
        # than the same token embedded in that echoed command.
        sudo_prompt_re = re.compile(
            rb"(?:^|\n)" + re.escape(sudo_prompt.encode()) + rb"\s*$"
        )
        output, state = read_until(ser, (sudo_prompt_re, marker_re), args.command_timeout)
        if state == 0:
            ser.write(args.password.encode() + b"\r")
            remainder, state = read_until(ser, (marker_re,), args.command_timeout)
            output += remainder

    decoded = output.decode("utf-8", "replace")
    sys.stdout.write(decoded)
    match = marker_re.search(clean(output))
    if state is None or match is None:
        print(f"[cerro-acm] command timed out after {args.command_timeout:g}s", file=sys.stderr)
        return 124
    return int(match.group(1))


if __name__ == "__main__":
    raise SystemExit(main())
