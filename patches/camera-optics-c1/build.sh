#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
cd "$base"
dtc -I dts -O dtb -o camera-lens-overlay.dtbo camera-lens-overlay.dts
python3 - <<'PY'
from pathlib import Path
p=Path('camera-lens-overlay.dtbo').read_bytes()
Path('camera-lens-overlay.inc').write_text(','.join('0x%02x'%x for x in p))
PY
make -C "${KERNEL_DIR:-$root/build/linux-7.2}" ARCH=arm64 LLVM=1 LOCALVERSION= M="$base" modules
llvm-strip --strip-debug ak7316-cerro.ko cerro-camera-lens.ko
sha256sum ak7316-cerro.ko cerro-camera-lens.ko
