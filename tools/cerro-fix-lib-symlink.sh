#!/bin/sh
# Rescue: Debian merged-/usr — /lib must be symlink to usr/lib.
# Never extract a tar that contains a real directory named lib/ onto /.
set -eu
if [ -L /lib ]; then
  echo "OK: /lib already symlink -> $(readlink /lib)"
  exit 0
fi
if [ ! -d /usr/lib ]; then
  echo "FAIL: /usr/lib missing" >&2
  exit 1
fi
# Preserve any modules we dropped into the bogus /lib
if [ -d /lib/modules ] && [ ! -e /usr/lib/modules/7.2.0-rc5-dirty/kernel/drivers/media/platform/qcom/camss/qcom-camss.ko ]; then
  mkdir -p /usr/lib/modules
  cp -a /lib/modules/. /usr/lib/modules/ || true
fi
rm -rf /lib
ln -sfn usr/lib /lib
echo "FIXED: /lib -> usr/lib"
ls -la /lib /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
