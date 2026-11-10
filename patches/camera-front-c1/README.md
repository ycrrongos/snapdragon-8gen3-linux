# Native OV12D2Q front camera — Cerro

Native V4L2/CCI sensor and a once-per-boot board graph. Runtime power/clock and
read-only ID probe passed:300b=1441 on CCI0/master0, driver bound, sensor suspended
and shared1.8V rail use count0 afterward. Normal cold graph plus actual30fpsRAW/RGB and3832x2160 GUI JPEG now pass.
Low-light automatic exposure and image quality remain unfinished.
Mode0/full3840x2160 and mode1/binned1920x1080 byte-write tables are audited against
the exact factory module hash; no firmware/vendor implementation/calibration is
included. The stream and reset registers are owned by the driver.

```sh
sh patches/camera-front-c1/build.sh
```

To reproduce the register header from your lawful local copy:

```sh
python3 patches/camera-front-c1/export-registers.py PRIVATE_MODULE.bin patches/camera-front-c1/ov12d2q-regs.h
```

Do not load the graph twice or rebind a live CAMSS to hide notifier ordering.
Normal startup must add main and front graphs before CAMSS's first probe.
Front sensor is fixed focus. BGGR is backed by the Android static inventory;
real capture, exposure timing and colour remain to validate. This driver has no
OIS, lens control, EEPROM access or flash operations.

Reference for sensor ID/control semantics:
[Rockchip Linux OV12D2Q](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/media/i2c/ov12d2q.c).
Cerro power sequence and mode tables differ; copying that board's register/power
setup would not be a valid port. Per-file GPL notices are retained.
