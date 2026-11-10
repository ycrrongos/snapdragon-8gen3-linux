#!/usr/bin/env python3
"""Copy one local file to Cerro through its stable USB ACM console."""

from __future__ import annotations

import argparse
import base64
import importlib.util
import os
from pathlib import Path
import re
import shlex
import sys
import time

import serial
from cerro_debug_credentials import defaults, password_or_prompt


def load_acm_helper():
    helper_path = Path(__file__).with_name("cerro-acm-run.py")
    spec = importlib.util.spec_from_file_location("cerro_acm_run", helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {helper_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("local", type=Path)
    parser.add_argument("remote")
    parser.add_argument("--port")
    username, password = defaults()
    parser.add_argument("--user", default=username)
    parser.add_argument("--password", default=password)
    parser.add_argument("--mode", default="0755")
    parser.add_argument("--sudo", action="store_true", help="install the final file as root")
    # ttyGS0/getty on this image truncates long canonical input lines well below
    # the usual 4 KiB limit. Keep the encoded payload comfortably under it.
    parser.add_argument("--chunk-size", type=int, default=512)
    args = parser.parse_args()
    args.password = password_or_prompt(args.password)

    content = base64.b64encode(args.local.read_bytes()).decode("ascii")
    helper = load_acm_helper()
    port = helper.choose_port(args.port)
    print(f"[cerro-acm-push] port={port} -> {os.path.realpath(port)}", file=sys.stderr)

    temp_base = f"/tmp/.cerro-push-{os.getpid()}"
    marker_counter = 0

    with serial.Serial(port, 115200, timeout=0.2, write_timeout=3.0) as ser:
        helper.login(ser, args.user, args.password, 25.0, reset_prompt=True)
        ser.reset_input_buffer()

        def remote(command: str, timeout: float = 20.0) -> None:
            nonlocal marker_counter
            marker_counter += 1
            marker = f"__CERRO_PUSH_{os.getpid()}_{marker_counter}__"
            payload = f"({command}); _rc=$?; printf '\\n{marker}:%s\\n' \"$_rc\"\n"
            ser.write(payload.encode())
            pattern = re.compile(re.escape(marker.encode()) + rb":([0-9]+)")
            output, state = helper.read_until(ser, (pattern,), timeout)
            match = pattern.search(helper.clean(output))
            if state is None or match is None:
                raise RuntimeError(f"remote command timed out: {command}")
            if int(match.group(1)) != 0:
                visible = helper.clean(output).decode("utf-8", "replace")
                raise RuntimeError(f"remote command failed: {command}\n{visible}")

        remote(f": > {shlex.quote(temp_base + '.b64')}")
        total = len(content)
        for offset in range(0, total, args.chunk_size):
            chunk = content[offset : offset + args.chunk_size]
            remote(
                f"printf %s {shlex.quote(chunk)} >> {shlex.quote(temp_base + '.b64')}"
            )
            done = min(offset + args.chunk_size, total)
            print(f"\r[cerro-acm-push] {done}/{total} base64 bytes", end="", file=sys.stderr)
        print(file=sys.stderr)
        remote(
            f"base64 -d {shlex.quote(temp_base + '.b64')} > {shlex.quote(temp_base)}"
        )
        parent = str(Path(args.remote).parent)
        if args.sudo:
            remote(f"sudo -n mkdir -p {shlex.quote(parent)}")
            remote(
                f"sudo -n install -m {shlex.quote(args.mode)} "
                f"{shlex.quote(temp_base)} {shlex.quote(args.remote)}"
            )
        else:
            remote(f"mkdir -p {shlex.quote(parent)}")
            remote(
                f"install -m {shlex.quote(args.mode)} "
                f"{shlex.quote(temp_base)} {shlex.quote(args.remote)}"
            )
        remote(f"rm -f {shlex.quote(temp_base)} {shlex.quote(temp_base + '.b64')}")

    print(f"[cerro-acm-push] installed {args.remote}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
