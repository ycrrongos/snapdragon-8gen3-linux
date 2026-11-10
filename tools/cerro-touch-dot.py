#!/usr/bin/env python3
"""Fullscreen touch visualizer: circle per MT contact (raw evdev, protocol B).

Usage on phone (pmOS / KDE Wayland or X11):
  sudo chmod a+r /dev/input/eventX
  GDK_SCALE=1 GDK_DPI_SCALE=1 python3 cerro-touch-dot.py

Esc / q / Ctrl-C to quit.
"""
from __future__ import annotations

# Force 1:1 before GTK init — Plasma scale otherwise enlarges the window.
import os
import sys

os.environ["GDK_SCALE"] = "1"
os.environ["GDK_DPI_SCALE"] = "1"
if os.environ.get("WAYLAND_DISPLAY") or any(
    True for _ in __import__("glob").glob("/run/user/*/wayland-0")
):
    os.environ.setdefault("GDK_BACKEND", "wayland")
    if not os.environ.get("WAYLAND_DISPLAY"):
        import glob as _glob

        for p in sorted(_glob.glob("/run/user/*/wayland-0")):
            os.environ["XDG_RUNTIME_DIR"] = os.path.dirname(p)
            os.environ["WAYLAND_DISPLAY"] = "wayland-0"
            break
elif not os.environ.get("DISPLAY"):
    os.environ["DISPLAY"] = ":0"

import array
import fcntl
import glob
import struct
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

EV_ABS = 0x03
EV_KEY = 0x01
EV_SYN = 0x00
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
BTN_TOUCH = 0x14A
SYN_REPORT = 0

SLOT_COLORS = [
    (1.0, 0.2, 0.2),
    (0.2, 0.9, 0.3),
    (0.2, 0.5, 1.0),
    (1.0, 0.85, 0.1),
    (1.0, 0.4, 0.9),
    (0.1, 0.9, 0.9),
    (1.0, 0.55, 0.1),
    (0.7, 0.7, 1.0),
    (0.6, 1.0, 0.4),
    (1.0, 0.6, 0.6),
]

# Panel mode (BF068 / RM692H0)
PANEL_W = 1116
PANEL_H = 2480


def EVIOCGABS(axis: int) -> int:
    size = 24
    return (2 << 30) | (ord("E") << 8) | (0x40 + axis) | (size << 16)


def read_absinfo(fd: int, axis: int) -> tuple[int, int, int]:
    buf = array.array("i", [0] * 6)
    fcntl.ioctl(fd, EVIOCGABS(axis), buf, True)
    return buf[1], buf[2], buf[0]


def drm_mode_size() -> tuple[int, int] | None:
    for path in sorted(glob.glob("/sys/class/drm/*/modes")):
        try:
            line = open(path, encoding="utf-8").readline().strip()
        except OSError:
            continue
        if "x" in line and line[0].isdigit():
            w, h = line.split("x", 1)
            h = h.split()[0]
            try:
                return int(w), int(h)
            except ValueError:
                pass
    return None


def find_goodix_event() -> str:
    try:
        text = open("/proc/bus/input/devices", encoding="utf-8", errors="replace").read()
    except OSError:
        text = ""
    event = None
    block: list[str] = []
    for line in text.splitlines():
        if line.startswith("N: Name=") and "Goodix" in line and "Touch" in line:
            block = [line]
        elif block:
            block.append(line)
            if line.startswith("H: Handlers="):
                for tok in line.split():
                    if tok.startswith("event"):
                        event = tok
                break
            if line == "":
                block = []
    if event:
        return f"/dev/input/{event}"
    if len(sys.argv) > 1:
        return sys.argv[1]
    return "/dev/input/event0"


def screen_geometry() -> tuple[int, int, str]:
    """Prefer compositor geometry (already 1:1 with GDK_SCALE=1)."""
    disp = Gdk.Display.get_default()
    if disp is not None:
        try:
            mon = disp.get_primary_monitor() or disp.get_monitor(0)
            if mon is not None:
                g = mon.get_geometry()
                scale = mon.get_scale_factor()
                # With GDK_SCALE=1, geometry is physical-ish; still prefer it.
                print(f"gdk monitor {g.width}x{g.height} scale={scale}", file=sys.stderr)
                if g.width > 1 and g.height > 1:
                    return g.width, g.height, f"gdk:{g.width}x{g.height}@scale{scale}"
        except Exception as e:
            print(f"gdk geom: {e}", file=sys.stderr)
    drm = drm_mode_size()
    if drm:
        return drm[0], drm[1], f"drm:{drm[0]}x{drm[1]}"
    return PANEL_W, PANEL_H, f"fallback:{PANEL_W}x{PANEL_H}"


class TouchDot(Gtk.Window):
    def __init__(self, evdev_path: str):
        super().__init__(title="cerro-touch-dot")
        self.connect("destroy", Gtk.main_quit)
        self.connect("key-press-event", self.on_key)
        self.connect("realize", self.on_realize)

        self.sw, self.sh, self.size_src = screen_geometry()
        self.set_default_size(self.sw, self.sh)
        self.fullscreen()
        self.set_app_paintable(True)

        self.area = Gtk.DrawingArea()
        self.area.connect("draw", self.on_draw)
        self.area.connect("size-allocate", self.on_area_alloc)
        self.add(self.area)

        self.slots: dict[int, tuple[float, float]] = {}
        self.slot_raw_hud: dict[int, tuple[int, int]] = {}
        self.raw_xy = (0, 0)
        self.scr_xy = (0.0, 0.0)
        self.down = False
        self.radius = 48.0
        self.lock = threading.Lock()
        self._logged_win = False
        self.max_concurrent = 0
        self.area_w = self.sw
        self.area_h = self.sh

        self.fd = os.open(evdev_path, os.O_RDONLY | os.O_NONBLOCK)
        self.xmin, self.xmax, _ = read_absinfo(self.fd, ABS_MT_POSITION_X)
        self.ymin, self.ymax, _ = read_absinfo(self.fd, ABS_MT_POSITION_Y)
        self.ox_min = self.xmin
        self.ox_max = self.xmax
        self.oy_min = self.ymin
        self.oy_max = self.ymax

        print(
            f"evdev={evdev_path}\n"
            f"panel_map_src={self.size_src} → {self.sw}x{self.sh}\n"
            f"ABS_MT_X {self.xmin}..{self.xmax}\n"
            f"ABS_MT_Y {self.ymin}..{self.ymax}\n"
            f"MT-B only (ignore ABS_X/Y pointer emulation)",
            file=sys.stderr,
            flush=True,
        )

        self.cur_slot = 0
        self.slot_trk: dict[int, int] = {}
        self.slot_raw: dict[int, tuple[int, int]] = {}
        self.rx = self.xmin
        self.ry = self.ymin

        GLib.io_add_watch(self.fd, GLib.IO_IN, self.on_evdev)
        GLib.timeout_add(16, self.tick)
        GLib.timeout_add(200, self.ensure_fullscreen)

        css = Gtk.CssProvider()
        css.load_from_data(b"window { background-color: #000; }")
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def ensure_fullscreen(self):
        self.fullscreen()
        w = self.get_allocated_width()
        h = self.get_allocated_height()
        if not self._logged_win and w > 100 and h > 100:
            print(f"window ok {w}x{h} area={self.area_w}x{self.area_h}", file=sys.stderr)
            self._logged_win = True
            return False
        return True

    def on_realize(self, *_a):
        self.fullscreen()

    def on_area_alloc(self, _w, alloc):
        if alloc.width > 1 and alloc.height > 1:
            self.area_w = alloc.width
            self.area_h = alloc.height

    def on_key(self, _w, ev):
        key = Gdk.keyval_name(ev.keyval) or ""
        if key in ("Escape", "q", "Q"):
            Gtk.main_quit()
        return True

    def map_range(self) -> tuple[int, int, int, int]:
        return (
            min(self.xmin, self.ox_min),
            max(self.xmax, self.ox_max),
            min(self.ymin, self.oy_min),
            max(self.ymax, self.oy_max),
        )

    def map_xy(self, x: int, y: int) -> tuple[float, float]:
        # Map into the DrawingArea only (not a stale DRM size).
        w = max(self.area_w, 1)
        h = max(self.area_h, 1)
        xmin, xmax, ymin, ymax = self.map_range()
        dx = max(xmax - xmin, 1)
        dy = max(ymax - ymin, 1)
        return (x - xmin) * w / dx, (y - ymin) * h / dy

    def on_evdev(self, _fd, _cond):
        fmt = "llHHi"
        size = struct.calcsize(fmt)
        try:
            while True:
                data = os.read(self.fd, size * 32)
                if not data:
                    break
                for off in range(0, len(data), size):
                    if off + size > len(data):
                        break
                    _sec, _usec, etype, code, value = struct.unpack_from(fmt, data, off)
                    if etype != EV_ABS and not (etype == EV_SYN and code == SYN_REPORT):
                        continue
                    if etype == EV_ABS:
                        if code == ABS_MT_SLOT:
                            self.cur_slot = value
                        elif code == ABS_MT_TRACKING_ID:
                            if value < 0:
                                self.slot_trk.pop(self.cur_slot, None)
                                self.slot_raw.pop(self.cur_slot, None)
                            else:
                                self.slot_trk[self.cur_slot] = value
                                self.slot_raw.setdefault(
                                    self.cur_slot, (self.rx, self.ry)
                                )
                        elif code == ABS_MT_POSITION_X:
                            # Do NOT handle ABS_X — pointer emulation overwrites last slot.
                            self.rx = value
                            self.ox_min = min(self.ox_min, value)
                            self.ox_max = max(self.ox_max, value)
                            _x, y = self.slot_raw.get(self.cur_slot, (value, self.ry))
                            self.slot_raw[self.cur_slot] = (value, y)
                        elif code == ABS_MT_POSITION_Y:
                            self.ry = value
                            self.oy_min = min(self.oy_min, value)
                            self.oy_max = max(self.oy_max, value)
                            x, _y = self.slot_raw.get(self.cur_slot, (self.rx, value))
                            self.slot_raw[self.cur_slot] = (x, value)
                    elif etype == EV_SYN and code == SYN_REPORT:
                        with self.lock:
                            active: dict[int, tuple[float, float]] = {}
                            raws: dict[int, tuple[int, int]] = {}
                            for sid, trk in self.slot_trk.items():
                                if trk < 0:
                                    continue
                                rx, ry = self.slot_raw.get(sid, (self.rx, self.ry))
                                raws[sid] = (rx, ry)
                                active[sid] = self.map_xy(rx, ry)
                            self.slots = active
                            self.slot_raw_hud = raws
                            self.down = bool(active)
                            self.max_concurrent = max(self.max_concurrent, len(active))
                            if active:
                                sid0 = min(active)
                                self.scr_xy = active[sid0]
                                self.raw_xy = raws[sid0]
                        n = len(self.slots)
                        if n >= 2:
                            parts = [
                                f"{sid}:({self.slot_raw_hud[sid][0]},{self.slot_raw_hud[sid][1]})"
                                for sid in sorted(self.slot_raw_hud)
                            ]
                            print(
                                f"fingers={n} max={self.max_concurrent} {', '.join(parts)}",
                                file=sys.stderr,
                                flush=True,
                            )
        except BlockingIOError:
            pass
        except OSError as e:
            print(f"evdev read: {e}", file=sys.stderr)
            return False
        return True

    def tick(self):
        self.area.queue_draw()
        return True

    def on_draw(self, _area, cr):
        alloc = self.area.get_allocation()
        cr.set_source_rgb(0, 0, 0)
        cr.rectangle(0, 0, alloc.width, alloc.height)
        cr.fill()

        cr.set_source_rgb(0.15, 0.15, 0.15)
        cr.set_line_width(2)
        cr.move_to(alloc.width / 2, 0)
        cr.line_to(alloc.width / 2, alloc.height)
        cr.move_to(0, alloc.height / 2)
        cr.line_to(alloc.width, alloc.height / 2)
        cr.stroke()

        with self.lock:
            slots = dict(self.slots)
            raws = dict(self.slot_raw_hud)
            down = self.down
            nmax = self.max_concurrent

        for sid, (x, y) in slots.items():
            r, g, b = SLOT_COLORS[sid % len(SLOT_COLORS)]
            cr.set_source_rgb(r, g, b)
            cr.arc(x, y, self.radius, 0, 6.28318)
            cr.fill()
            cr.set_source_rgb(1, 1, 1)
            cr.set_line_width(3)
            cr.arc(x, y, self.radius, 0, 6.28318)
            cr.stroke()
            cr.set_font_size(32)
            cr.move_to(x - 10, y + 12)
            cr.show_text(str(sid))

        cr.set_source_rgb(0.75, 0.75, 0.75)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(22)
        detail = " ".join(
            f"{sid}:{raws[sid][0]},{raws[sid][1]}" for sid in sorted(raws)
        )
        line = (
            f"fingers={len(slots)} max={nmax}  area={alloc.width}x{alloc.height}  "
            f"{detail}  {'DOWN' if down else 'up'}  Esc=quit"
        )
        cr.move_to(12, 36)
        cr.show_text(line)
        return False


def main() -> int:
    if not os.environ.get("XAUTHORITY") and os.environ.get("DISPLAY"):
        xs = sorted(glob.glob("/run/user/*/xauth_*"))
        if xs:
            os.environ["XAUTHORITY"] = xs[0]

    path = sys.argv[1] if len(sys.argv) > 1 else find_goodix_event()
    if not os.path.exists(path):
        print(f"missing {path}", file=sys.stderr)
        return 1
    win = TouchDot(path)
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
