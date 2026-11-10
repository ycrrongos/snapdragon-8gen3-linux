#!/usr/bin/env python3
"""Watch Cerro USB mode and Linux journal together.

A bare lsusb gap looks like an unplug. This process records the USB mode every
poll and, while ACM is up, pulls new journal lines. If the boot id changes, it
dumps the previous boot's errors before they scroll away.

Logs:
  /tmp/cerro-state-watch.log
  /tmp/cerro-state-watch.status
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

LOG = Path("/tmp/cerro-state-watch.log")
STATUS = Path("/tmp/cerro-state-watch.status")
POLL_S = 0.4
ACM_EVERY_S = 2.0

HELPER = Path(__file__).with_name("cerro-acm-run.py")


def load_helper():
    spec = importlib.util.spec_from_file_location("cerro_acm_run", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stamp() -> str:
    return time.strftime("%H:%M:%S")


def write_log(line: str) -> None:
    text = f"{stamp()} {line}\n"
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(text)
    sys.stdout.write(text)
    sys.stdout.flush()


def write_status(line: str) -> None:
    STATUS.write_text(f"{stamp()} {line}\n", encoding="utf-8")


def usb_mode() -> str:
    try:
        raw = subprocess.check_output(["lsusb"], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        raw = ""
    if re.search(r"05c6:9008", raw, re.I):
        return "edl"
    if re.search(r"19d2:0112", raw, re.I):
        return "dump"
    if re.search(r"18d1:d00d", raw, re.I):
        return "fastboot"
    if re.search(r"18d1:4e", raw, re.I):
        return "android"
    acm = list(Path("/dev/serial/by-id").glob("*nubia*cerro-debug-if00")) if Path("/dev/serial/by-id").is_dir() else []
    if re.search(r"1d6b:0104", raw) and acm:
        return "linux+acm"
    if re.search(r"1d6b:0104", raw):
        return "linux"
    if acm:
        return "acm-only"
    return "none"


PROBE = (
    "b=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); "
    "u=$(cut -d. -f1 /proc/uptime); "
    "s=$(systemctl is-active sddm 2>/dev/null || echo na); "
    "echo BOOT=$b UPT=$u SDDM=$s; "
    "echo user | sudo -S -p '' journalctl -b -o cat --no-pager "
    "-p err --cursor-file=/tmp/cerro-jcur -n 20 2>/dev/null | tail -20"
)

PREV = (
    "echo user | sudo -S -p '' sh -c '"
    "journalctl -b -1 -p err -o short-monotonic --no-pager | tail -40; "
    "echo ----; "
    "journalctl -b -1 --no-pager | grep -E \"dumped core|segfault|Kernel panic|Oops|watchdog\" | tail -20"
    "'"
)


def main() -> int:
    helper = load_helper()
    write_log("watch start")
    state = {"mode": "", "boot": "", "upt": ""}
    lock = threading.Lock()

    def usb_loop() -> None:
        last = ""
        while True:
            mode = usb_mode()
            with lock:
                prev = state["mode"]
                state["mode"] = mode
                boot = state["boot"]
                upt = state["upt"]
            if mode != last:
                extra = f" last_boot={boot or '-'} last_upt={upt or '-'}"
                if last in ("linux", "linux+acm", "acm-only") and mode == "none":
                    write_log(f"USB {last} -> none (link lost; crash if boot id changes on return){extra}")
                elif last and mode in ("dump", "edl", "fastboot", "android"):
                    write_log(f"USB {last} -> {mode} CRASH_OR_REBOOT{extra}")
                else:
                    write_log(f"USB {last or 'start'} -> {mode}{extra}")
                write_status(f"mode={mode} boot={boot or '-'} upt={upt or '-'}")
                last = mode
            time.sleep(POLL_S)

    threading.Thread(target=usb_loop, daemon=True).start()

    while True:
        try:
            port = helper.choose_port(None)
        except SystemExit:
            time.sleep(0.5)
            continue
        try:
            import serial

            ser = serial.Serial(port, 115200, timeout=0.2, write_timeout=2.0)
        except Exception as exc:
            write_log(f"ACM open fail {exc}")
            time.sleep(1)
            continue
        try:
            helper.login(ser, "user", "user", 12.0, reset_prompt=True)
            write_log(f"ACM login {port}")
            seen_boot = ""
            while True:
                ser.reset_input_buffer()
                marker = f"__W_{os.getpid()}_{int(time.time())}__"
                payload = f"({PROBE}); printf '\\n{marker}:%s\\n' $?\n"
                ser.write(payload.encode())
                marker_re = re.compile(re.escape(marker.encode()) + rb":([0-9]+)")
                output, found = helper.read_until(ser, (marker_re,), 8.0)
                text = helper.clean(output).decode("utf-8", "replace")
                if found is None:
                    write_log("ACM probe timeout")
                    break
                boot_m = re.search(r"BOOT=([0-9a-f-]+)", text)
                upt_m = re.search(r"UPT=(\d+)", text)
                sddm_m = re.search(r"SDDM=(\S+)", text)
                boot = boot_m.group(1) if boot_m else ""
                upt = upt_m.group(1) if upt_m else ""
                sddm = sddm_m.group(1) if sddm_m else "?"
                with lock:
                    prev_boot = state["boot"]
                    state["boot"] = boot
                    state["upt"] = upt
                    mode = state["mode"]
                write_status(f"mode={mode} boot={boot} upt={upt}s sddm={sddm}")
                if boot and boot != seen_boot:
                    if prev_boot and boot != prev_boot:
                        write_log(f"REBOOT boot {prev_boot} -> {boot} (not a USB unplug)")
                        ser.reset_input_buffer()
                        marker2 = f"__P_{os.getpid()}__"
                        ser.write(f"({PREV}); printf '\\n{marker2}:%s\\n' $?\n".encode())
                        marker2_re = re.compile(re.escape(marker2.encode()) + rb":([0-9]+)")
                        prev_out, _ = helper.read_until(ser, (marker2_re,), 20.0)
                        prev_text = helper.clean(prev_out).decode("utf-8", "replace")
                        for line in prev_text.splitlines():
                            if line.startswith("__P_") or "user" in line:
                                continue
                            if line.strip():
                                write_log(f"prev {line[:240]}")
                    else:
                        write_log(f"BOOT {boot} upt={upt}s sddm={sddm}")
                    seen_boot = boot
                body = []
                for line in text.splitlines():
                    if line.startswith("BOOT=") or line.startswith(marker) or "user" in line:
                        continue
                    if "cursor-file" in line or line.startswith("["):
                        continue
                    stripped = line.strip()
                    if stripped:
                        body.append(stripped[:240])
                noise = ("No entries", "nubia-cerro", "UTF-8", "locale(1)", "password")
                body = [line for line in body if not any(tok in line for tok in noise)]
                if body:
                    write_log("journal " + " | ".join(body[-8:]))
                time.sleep(ACM_EVERY_S)
        except Exception as exc:
            with lock:
                boot = state["boot"]
                upt = state["upt"]
                mode = state["mode"]
            write_log(f"ACM drop mode={mode} boot={boot or '-'} upt={upt or '-'} err={exc}")
        finally:
            try:
                ser.close()
            except Exception:
                pass
        time.sleep(0.5)


if __name__ == "__main__":
    raise SystemExit(main())
