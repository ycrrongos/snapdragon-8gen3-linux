#!/usr/bin/env python3
"""Cerro power key v2 — PowerDevil blank/wake only (no cerro-dpms / no sysfs brightness).

Short press: PowerDevil "Turn Off Screen" or wakeup (panel stays unlocked → touch/double-tap wakes).
Long press ≥3s: Plasma LogoutPrompt.

Do NOT call /usr/local/sbin/cerro-dpms (SEGV / brightness=0 hard-crash history 2026-10-15).
"""
from __future__ import annotations

import os
import select
import subprocess
import sys
import time

import libevdev

LONG_PRESS_SEC = 3.0
USER = "rong"
UID = 1000
RUNTIME = f"/run/user/{UID}"
BUS = f"unix:path={RUNTIME}/bus"


def find_power_device() -> str:
    for ent in os.listdir("/sys/class/input"):
        if not ent.startswith("event"):
            continue
        try:
            with open(f"/sys/class/input/{ent}/device/name", encoding="utf-8") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "pmic_pwrkey":
            return f"/dev/input/{ent}"
    raise SystemExit("pmic_pwrkey not found")


def run_user(argv: list[str], timeout: float = 8.0) -> int:
    cmd = [
        "/usr/sbin/runuser",
        "-u",
        USER,
        "--",
        "env",
        f"XDG_RUNTIME_DIR={RUNTIME}",
        f"DBUS_SESSION_BUS_ADDRESS={BUS}",
        "WAYLAND_DISPLAY=wayland-0",
        "QT_QPA_PLATFORM=wayland",
        f"HOME=/home/{USER}",
        f"USER={USER}",
        "LANG=C.UTF-8",
        *argv,
    ]
    try:
        r = subprocess.run(
            cmd,
            timeout=timeout,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return r.returncode
    except subprocess.TimeoutExpired:
        return 124


def session_alive() -> bool:
    return os.path.exists(f"{RUNTIME}/bus") and os.path.exists(f"{RUNTIME}/wayland-0")


def drm_dpms_off() -> bool:
    try:
        return open("/sys/class/drm/card0-DSI-1/dpms", encoding="utf-8").read().strip() == "Off"
    except OSError:
        return False


def screen_off() -> None:
    run_user(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.kglobalaccel",
            "/component/org_kde_powerdevil",
            "org.kde.kglobalaccel.Component",
            "invokeShortcut",
            "s",
            "Turn Off Screen",
        ]
    )


def screen_on() -> None:
    run_user(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.Solid.PowerManagement",
            "/org/kde/Solid/PowerManagement",
            "org.kde.Solid.PowerManagement",
            "wakeup",
        ]
    )


def screen_toggle() -> None:
    """Blank or wake via PowerDevil only."""
    if not session_alive():
        return
    if drm_dpms_off():
        screen_on()
    else:
        screen_off()


def power_menu() -> None:
    if not session_alive():
        return
    if drm_dpms_off():
        screen_on()
    run_user(
        [
            "busctl",
            "--user",
            "call",
            "org.kde.LogoutPrompt",
            "/LogoutPrompt",
            "org.kde.LogoutPrompt",
            "promptAll",
        ]
    )


def main() -> int:
    path = find_power_device()
    fd = open(path, "rb", buffering=0)
    dev = libevdev.Device(fd)
    try:
        dev.grab()
    except OSError as e:
        print(f"grab failed: {e}", file=sys.stderr)
        return 1
    print(
        f"cerro-powerkey: {path} short=PowerDevil blank/wake long≥{LONG_PRESS_SEC}s=menu",
        flush=True,
    )

    pressed_at: float | None = None
    long_fired = False

    while True:
        ready, _, _ = select.select([fd], [], [], 0.05)
        now = time.monotonic()
        if pressed_at is not None and not long_fired and (now - pressed_at) >= LONG_PRESS_SEC:
            long_fired = True
            print("long hold → power menu", flush=True)
            power_menu()
        if not ready:
            continue
        try:
            for event in dev.events():
                if not event.matches(libevdev.EV_KEY.KEY_POWER):
                    continue
                if event.value == 1:
                    pressed_at = time.monotonic()
                    long_fired = False
                elif event.value == 2:
                    if pressed_at is None:
                        pressed_at = time.monotonic()
                elif event.value == 0:
                    held = 0.0 if pressed_at is None else (time.monotonic() - pressed_at)
                    if pressed_at is not None and not long_fired:
                        if held >= LONG_PRESS_SEC:
                            print("long release → power menu", flush=True)
                            power_menu()
                        else:
                            print("short → PowerDevil blank/wake", flush=True)
                            screen_toggle()
                    pressed_at = None
                    long_fired = False
        except libevdev.EventsDropped:
            continue


if __name__ == "__main__":
    raise SystemExit(main())
