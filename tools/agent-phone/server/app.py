"""Web + serial bridge for agent-phone servos (ESP32 / STM32 / USB-UART)."""

from __future__ import annotations

import asyncio
import os
import re
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import serial
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

PORT = os.environ.get("SERVO_PORT", "")
BAUD = int(os.environ.get("SERVO_BAUD", "115200"))
STATIC_DIR = Path(__file__).parent / "static"

_lock = threading.Lock()
_ser: Optional[serial.Serial] = None
_last_ok = ""
_active_port = ""
_angles = {
    "volup": 90,
    "voldown": 90,
    "power": 90,
    "rest_volup": 90,
    "rest_voldown": 90,
    "rest_power": 90,
    "press_volup": 74,
    "press_voldown": 114,
    "press_power": 119,
}

_PORT_SCORE = (
    ("espressif", 100),
    ("usb_jtag_serial", 100),
    ("dfrobot", 95),
    ("firebeetle", 95),
    ("3343", 95),
    ("stmicroelectronics", 90),
    ("stm32", 90),
    ("maple", 85),
    ("usb_single_serial", 70),
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


def resolve_port() -> str:
    if PORT:
        return PORT
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
    for candidate in ("/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0"):
        if Path(candidate).exists():
            return candidate
    return "/dev/ttyACM0"


def _open_serial() -> serial.Serial:
    global _active_port
    port = resolve_port()
    _active_port = port
    ser = serial.Serial(port, BAUD, timeout=1.0, write_timeout=1.0)
    time.sleep(2.2)
    ser.reset_input_buffer()
    deadline = time.time() + 2.0
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="replace").strip()
        if "READY" in line:
            break
    return ser


def ensure_serial() -> serial.Serial:
    global _ser
    with _lock:
        if _ser is not None and _ser.is_open:
            return _ser
        try:
            _ser = _open_serial()
            return _ser
        except Exception as exc:
            raise HTTPException(status_code=503, detail=f"serial open failed: {exc}") from exc


def _parse_angles_reply(raw: str) -> None:
    # OK ANGLES U=90 D=90 P=90 RESTU=90 ...
    mapping = {
        "U": "volup",
        "D": "voldown",
        "P": "power",
        "RESTU": "rest_volup",
        "RESTD": "rest_voldown",
        "RESTP": "rest_power",
        "PRESSU": "press_volup",
        "PRESSD": "press_voldown",
        "PRESSP": "press_power",
    }
    for key, dest in mapping.items():
        m = re.search(rf"\b{key}=(\d+)", raw)
        if m:
            _angles[dest] = int(m.group(1))


def send_cmd(cmd: str, timeout: float = 3.0) -> str:
    global _last_ok
    ser = ensure_serial()
    with _lock:
        ser.reset_input_buffer()
        ser.write((cmd.strip() + "\n").encode("ascii"))
        ser.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            raw = ser.readline().decode("utf-8", errors="replace").strip()
            if not raw:
                continue
            if raw.startswith("OK") or raw.startswith("ERR"):
                _last_ok = raw
                if raw.startswith("OK ANGLES"):
                    _parse_angles_reply(raw)
                elif raw.startswith("OK SU:"):
                    _angles["volup"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK SD:"):
                    _angles["voldown"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK SP:"):
                    _angles["power"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK RESTU:"):
                    _angles["rest_volup"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK RESTD:"):
                    _angles["rest_voldown"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK RESTP:"):
                    _angles["rest_power"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK PRESSU:"):
                    _angles["press_volup"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK PRESSD:"):
                    _angles["press_voldown"] = int(raw.split(":", 1)[1])
                elif raw.startswith("OK PRESSP:"):
                    _angles["press_power"] = int(raw.split(":", 1)[1])
                return raw
        raise HTTPException(status_code=504, detail="no reply from device")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        ensure_serial()
        send_cmd("G")
    except HTTPException:
        pass
    yield
    with _lock:
        if _ser is not None and _ser.is_open:
            _ser.close()


app = FastAPI(title="Agent Phone Tool", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class CmdBody(BaseModel):
    cmd: str


class AngleBody(BaseModel):
    servo: str
    angle: int = Field(ge=0, le=180)


class AngleConfigBody(BaseModel):
    volup: Optional[int] = Field(default=None, ge=0, le=180)
    voldown: Optional[int] = Field(default=None, ge=0, le=180)
    power: Optional[int] = Field(default=None, ge=0, le=180)
    rest_volup: Optional[int] = Field(default=None, ge=0, le=180)
    rest_voldown: Optional[int] = Field(default=None, ge=0, le=180)
    rest_power: Optional[int] = Field(default=None, ge=0, le=180)
    press_volup: Optional[int] = Field(default=None, ge=0, le=180)
    press_voldown: Optional[int] = Field(default=None, ge=0, le=180)
    press_power: Optional[int] = Field(default=None, ge=0, le=180)


SERVO_SET_CMD = {
    "volup": "SU",
    "voldown": "SD",
    "power": "SP",
    "rest_volup": "RESTU",
    "rest_voldown": "RESTD",
    "rest_power": "RESTP",
    "press_volup": "PRESSU",
    "press_voldown": "PRESSD",
    "press_power": "PRESSP",
}

# Host-side tap hold times (seconds). Board only moves to angles.
PRESS_HOLD_S = {
    "volup": float(os.environ.get("PRESS_MS_VOL", "350")) / 1000.0,
    "voldown": float(os.environ.get("PRESS_MS_VOL", "350")) / 1000.0,
    "power": float(os.environ.get("PRESS_MS_POWER", "500")) / 1000.0,
}
SETTLE_S = 0.2


def _normalize_button(button: str) -> str:
    raw = button.lower().replace("-", "").replace("_", "")
    if button.lower() in ("vol+", "volup", "volumeup") or raw in ("volup", "vol+", "volumeup"):
        return "volup"
    if button.lower() in ("vol-", "voldown", "volumedown") or raw in ("voldown", "vol-", "volumedown"):
        return "voldown"
    if raw in ("power", "pwr"):
        return "power"
    if raw in ("reset", "r"):
        return "reset"
    return raw


def local_tap(servo: str) -> str:
    """Press then release on the host; board only receives angle writes."""
    prefix = SERVO_SET_CMD[servo]
    press_a = int(_angles[f"press_{servo}"])
    rest_a = int(_angles[f"rest_{servo}"])
    send_cmd(f"{prefix}:{press_a}")
    time.sleep(PRESS_HOLD_S[servo])
    send_cmd(f"{prefix}:{rest_a}")
    time.sleep(SETTLE_S)
    return f"OK {servo.upper()} local press={press_a} rest={rest_a}"


def local_reset() -> str:
    for servo in ("volup", "voldown", "power"):
        prefix = SERVO_SET_CMD[servo]
        send_cmd(f"{prefix}:{int(_angles[f'rest_{servo}'])}")
    time.sleep(SETTLE_S)
    return "OK RESET local"


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/status")
def status():
    connected = False
    with _lock:
        connected = _ser is not None and _ser.is_open
    if not connected:
        try:
            ensure_serial()
            connected = True
        except HTTPException:
            connected = False
    return {
        "connected": connected,
        "port": _active_port or resolve_port(),
        "baud": BAUD,
        "last": _last_ok,
        "angles": _angles,
    }


@app.get("/api/angles")
async def get_angles():
    result = await asyncio.to_thread(send_cmd, "G")
    return {"ok": True, "reply": result, "angles": _angles}


@app.post("/api/angle")
async def set_angle(body: AngleBody):
    prefix = SERVO_SET_CMD.get(body.servo.lower())
    if not prefix:
        raise HTTPException(status_code=400, detail=f"unknown servo: {body.servo}")
    result = await asyncio.to_thread(send_cmd, f"{prefix}:{body.angle}")
    return {"ok": result.startswith("OK"), "reply": result, "angles": _angles}


@app.post("/api/angles")
async def set_angles(body: AngleConfigBody):
    replies = []
    for key, value in body.model_dump(exclude_none=True).items():
        prefix = SERVO_SET_CMD.get(key)
        if not prefix:
            continue
        replies.append(await asyncio.to_thread(send_cmd, f"{prefix}:{value}"))
    if not replies:
        raise HTTPException(status_code=400, detail="no angles provided")
    return {"ok": all(r.startswith("OK") for r in replies), "replies": replies, "angles": _angles}


@app.post("/api/cmd")
async def api_cmd(body: CmdBody):
    cmd = body.cmd.strip().upper()
    # Host-side taps (board no longer handles U/D/P)
    if cmd in {"U", "VOL+", "VOLUP"}:
        result = await asyncio.to_thread(local_tap, "volup")
        return {"ok": True, "reply": result, "angles": _angles}
    if cmd in {"D", "VOL-", "VOLDOWN"}:
        result = await asyncio.to_thread(local_tap, "voldown")
        return {"ok": True, "reply": result, "angles": _angles}
    if cmd in {"P", "POWER"}:
        result = await asyncio.to_thread(local_tap, "power")
        return {"ok": True, "reply": result, "angles": _angles}
    if cmd in {"R", "RESET"}:
        result = await asyncio.to_thread(local_reset)
        return {"ok": True, "reply": result, "angles": _angles}

    simple = {"PING", "G", "GET", "ANGLES"}
    ok = cmd in simple or re.fullmatch(
        r"(SU|SD|SP|SA|RESTU|RESTD|RESTP|PRESSU|PRESSD|PRESSP):[0-9,]+", cmd
    )
    if not ok:
        raise HTTPException(status_code=400, detail=f"cmd not allowed: {cmd}")
    result = await asyncio.to_thread(send_cmd, cmd)
    return {"ok": result.startswith("OK"), "reply": result, "angles": _angles}


@app.post("/api/press/{button}")
async def press(button: str):
    key = _normalize_button(button)
    if key == "reset":
        result = await asyncio.to_thread(local_reset)
        return {"ok": True, "reply": result, "button": key, "angles": _angles}
    if key not in ("volup", "voldown", "power"):
        raise HTTPException(status_code=404, detail="unknown button")
    result = await asyncio.to_thread(local_tap, key)
    return {"ok": True, "reply": result, "button": key, "angles": _angles}


class HoldBody(BaseModel):
    seconds: float = Field(default=12.0, ge=1.0, le=60.0)
    buttons: Optional[list[str]] = None  # default: all three for EDL


def local_hold(seconds: float, buttons: Optional[list[str]] = None) -> str:
    keys = buttons or ["volup", "voldown", "power"]
    keys = [_normalize_button(b) for b in keys]
    for k in keys:
        if k not in ("volup", "voldown", "power"):
            raise HTTPException(status_code=400, detail=f"bad button: {k}")
    # Simultaneous: SA:pressU,pressD,pressP
    press = (
        int(_angles["press_volup"]),
        int(_angles["press_voldown"]),
        int(_angles["press_power"]),
    )
    rest = (
        int(_angles["rest_volup"]),
        int(_angles["rest_voldown"]),
        int(_angles["rest_power"]),
    )
    # Map only requested buttons to press angle; others stay at rest
    u = press[0] if "volup" in keys else rest[0]
    d = press[1] if "voldown" in keys else rest[1]
    p = press[2] if "power" in keys else rest[2]
    send_cmd(f"SA:{u},{d},{p}")
    time.sleep(seconds)
    send_cmd(f"SA:{rest[0]},{rest[1]},{rest[2]}")
    time.sleep(SETTLE_S)
    return f"OK HOLD {','.join(keys)} {seconds}s"


@app.post("/api/hold")
async def api_hold(body: HoldBody):
    """Hold one or more buttons (default all three = EDL recipe)."""
    result = await asyncio.to_thread(local_hold, body.seconds, body.buttons)
    return {"ok": True, "reply": result, "angles": _angles}


@app.post("/api/hold-edl")
async def api_hold_edl(seconds: float = 12.0):
    """Cerro EDL: Power + Vol+ + Vol- for ~12s."""
    result = await asyncio.to_thread(local_hold, float(seconds), None)
    return {"ok": True, "reply": result, "angles": _angles}
