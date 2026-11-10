#!/bin/sh
set -eu
base=/home/user/cerro-mm-build
cd "$base"
test -d mm-src || tar -xf mm-src.tar
export PATH="$base/sysroot/usr/bin:$PATH"
export PYTHONPATH="$base/sysroot/usr/lib/python3/dist-packages"
export LD_LIBRARY_PATH="$base/sysroot/usr/lib/aarch64-linux-gnu"
export PKG_CONFIG_SYSROOT_DIR="$base/sysroot"
export PKG_CONFIG_LIBDIR="$base/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$base/sysroot/usr/share/pkgconfig"
export CC=cc
meson setup out mm-src --prefix=/usr -Dintrospection=false -Dvapi=false -Dgtk_doc=false -Dman=false -Dbash_completion=false -Dsystemdsystemunitdir=/lib/systemd/system -Dudevdir=/lib/udev -Dqrtr=true -Dqmi=true -Dmbim=true -Dpolkit=permissive
ninja -C out -j 6 src/ModemManager
