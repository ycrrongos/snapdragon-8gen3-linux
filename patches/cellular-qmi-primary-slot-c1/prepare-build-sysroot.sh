#!/bin/sh
set -eu
base=/home/user/cerro-mm-build
mkdir -p "$base/cache/partial" "$base/sysroot"
apt-get -y --download-only --no-install-recommends -o Dir::Cache::archives="$base/cache" install meson ninja-build pkg-config libglib2.0-dev libgudev-1.0-dev libdbus-1-dev libqmi-glib-dev libmbim-glib-dev libqrtr-glib-dev libpolkit-gobject-1-dev libsystemd-dev xsltproc gettext libtool autoconf automake
for pkg in "$base"/cache/*.deb; do dpkg-deb -x "$pkg" "$base/sysroot"; done
chown -R user:user "$base"
