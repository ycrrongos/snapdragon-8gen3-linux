#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
k="$root/build/linux-7.2"
cd "$base"
dtc -I dts -O dtb -o camera-identify-overlay.dtbo camera-identify-overlay.dts
python3 - <<'PY'
from pathlib import Path
p=Path('camera-identify-overlay.dtbo').read_bytes()
Path('camera-identify-overlay.inc').write_text(','.join('0x%02x'%b for b in p))
PY
make -C "$k" ARCH=arm64 LLVM=1 LOCALVERSION= M="$base" modules
llvm-strip --strip-debug cerro-camera-id.ko
sha256sum cerro-camera-id.ko
