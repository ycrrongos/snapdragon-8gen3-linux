#!/bin/sh
set -eu
base=/home/user/cerro-camera-build
mkdir -p "$base/cache/partial" "$base/sysroot"
apt-get -y --download-only --no-install-recommends -o Dir::Cache::archives="$base/cache" install python3-jinja2 python3-yaml python3-ply libyaml-dev libevent-dev libudev-dev qt6-base-dev
for pkg in "$base"/cache/*.deb; do dpkg-deb -x "$pkg" "$base/sysroot"; done
chown -R user:user "$base"
