#!/bin/sh
set -eu
base=/home/user/cerro-camera-build
cd "$base"
if ! test -d libcamera-src; then tar -xf /home/user/libcamera-src.tar; fi
python3 - <<'PY'
from pathlib import Path
root=Path('/home/user/cerro-camera-build/sysroot/usr/lib/aarch64-linux-gnu')
runtime=Path('/usr/lib/aarch64-linux-gnu')
for p in root.glob('*.so'):
 if p.exists():continue
 target=next((x for x in runtime.glob(p.name+'.*') if x.is_file()),None)
 if target:
  if p.is_symlink():p.unlink()
  p.symlink_to(target)
PY
export PATH="/home/user/cerro-mm-build/sysroot/usr/bin:$PATH"
export PYTHONPATH="$base/sysroot/usr/lib/python3/dist-packages:/home/user/cerro-mm-build/sysroot/usr/lib/python3/dist-packages"
export LD_LIBRARY_PATH="$base/sysroot/usr/lib/aarch64-linux-gnu:/home/user/cerro-mm-build/sysroot/usr/lib/aarch64-linux-gnu"
export CPATH="$base/sysroot/usr/include"
export PKG_CONFIG_SYSROOT_DIR="$base/sysroot"
export PKG_CONFIG_LIBDIR="$base/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$base/sysroot/usr/share/pkgconfig"
meson setup --reconfigure --clearcache out libcamera-src --buildtype=release -Dc_args="-I$base/sysroot/usr/include" -Dcpp_args="-I$base/sysroot/usr/include" --prefix=/opt/cerro-camera --libdir=lib -Dpipelines=simple -Dipas=simple -Dcam=enabled -Dqcam=disabled -Ddocumentation=disabled -Dgstreamer=disabled -Dpycamera=disabled -Dtest=false -Dtracing=disabled -Dlc-compliance=disabled -Dudev=enabled
ninja -C out -j6
DESTDIR="$base/staged" meson install -C out --no-rebuild
