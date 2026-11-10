#!/bin/sh
set -eu
base=/home/user/cerro-camera-build
cd "$base"
if ! test -d libcamera-0.8.0; then
 printf '%s  %s\n' 5ecea748d40d531ba1c977f56aab7180ce81871f6267e672968c7ace2a8dfdfd /home/user/libcamera-v0.8.0.tar.gz | sha256sum -c -
 tar -xf /home/user/libcamera-v0.8.0.tar.gz
 patch -d libcamera-0.8.0 -p1 < /home/user/0002-libcamera-08-imx800-helper.patch
fi
python3 - <<'PY'
from pathlib import Path
root=Path('/home/user/cerro-camera-build/sysroot/usr/lib/aarch64-linux-gnu');runtime=Path('/usr/lib/aarch64-linux-gnu')
for p in root.glob('*.so'):
 if p.exists():continue
 target=next((x for x in runtime.glob(p.name+'.*') if x.is_file()),None)
 if target:
  if p.is_symlink():p.unlink()
  p.symlink_to(target)
PY
mkdir -p "$base/qt-tools"
for program in moc rcc uic; do
 ln -sf "$base/sysroot/usr/lib/qt6/libexec/$program" "$base/qt-tools/${program}6"
done
export PATH="$base/qt-tools:$base/sysroot/usr/bin:/home/user/cerro-mm-build/sysroot/usr/bin:$PATH"
export PYTHONPATH="$base/sysroot/usr/lib/python3/dist-packages:/home/user/cerro-mm-build/sysroot/usr/lib/python3/dist-packages"
export LD_LIBRARY_PATH="$base/sysroot/usr/lib/aarch64-linux-gnu:/home/user/cerro-mm-build/sysroot/usr/lib/aarch64-linux-gnu"
export CPATH="$base/sysroot/usr/include"
export PKG_CONFIG_SYSROOT_DIR="$base/sysroot"
export PKG_CONFIG_LIBDIR="$base/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$base/sysroot/usr/share/pkgconfig"
meson setup --reconfigure out-08 libcamera-0.8.0 --buildtype=release --prefix=/opt/cerro-camera-0.8 --libdir=lib -Dpipelines=simple -Dipas=softisp -Dcam=enabled -Dqcam=enabled -Dsoftisp-gpu=disabled -Ddocumentation=disabled -Dgstreamer=disabled -Dpycamera=disabled -Dtest=false -Dtracing=disabled -Dlc-compliance=disabled -Dudev=enabled
ninja -C out-08 -j6
DESTDIR="$base/staged-08" meson install -C out-08 --no-rebuild
