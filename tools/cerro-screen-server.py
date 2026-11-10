#!/usr/bin/env python3
"""Cerro 投屏服务：KDE Wayland 截屏 -> MJPEG 流（仅标准库 + spectacle/convert）。

端点（默认 :8660）：
  /stream.mjpg  MJPEG 流（ffplay / 浏览器）
  /shot.jpg     单帧 JPEG
  /             简单网页查看器
帧率受 spectacle 截屏耗时限制（约 1-2 fps），用于夹具内观察屏幕足够。
"""

import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CERRO_SCREEN_PORT", "8660"))
WIDTH = int(os.environ.get("CERRO_SCREEN_WIDTH", "620"))
QUALITY = os.environ.get("CERRO_SCREEN_QUALITY", "60")
ENV = {
    **os.environ,
    "WAYLAND_DISPLAY": "wayland-0",
    "XDG_RUNTIME_DIR": "/run/user/1000",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
}
LOCK = threading.Lock()
PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>Cerro 投屏</title>
<style>body{background:#111;color:#eee;font-family:sans-serif;text-align:center}
img{max-height:92vh;border:1px solid #444;margin-top:8px}</style></head>
<body><h3>Cerro 投屏（约 1-2 fps）</h3><img src="/stream.mjpg"></body></html>
""".encode("utf-8")


def capture_frame():
    with LOCK:
        shot = subprocess.run(
            ["spectacle", "-f", "-b", "-o", "/tmp/cerro-screen-shot.png"],
            env=ENV, capture_output=True, timeout=15,
        )
        if shot.returncode != 0 or not os.path.exists("/tmp/cerro-screen-shot.png"):
            return None
        conv = subprocess.run(
            ["convert", "/tmp/cerro-screen-shot.png",
             "-resize", str(WIDTH), "-quality", QUALITY, "jpg:-"],
            capture_output=True, timeout=15,
        )
    if conv.returncode != 0 or not conv.stdout:
        return None
    return conv.stdout


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith("/shot"):
            frame = capture_frame()
            if frame is None:
                self.send_error(500, "capture failed")
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(frame)
        elif self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=cerroframe")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            while True:
                frame = capture_frame()
                if frame is None:
                    time.sleep(0.5)
                    continue
                try:
                    self.wfile.write(
                        b"--cerroframe\r\nContent-Type: image/jpeg\r\n"
                        b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n"
                        + frame + b"\r\n"
                    )
                except (BrokenPipeError, ConnectionResetError):
                    return
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(PAGE)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"cerro-screen-server listening on :{PORT} width={WIDTH}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
