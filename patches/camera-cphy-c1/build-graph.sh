#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
cd "$base"
dtc -I dts -O dtb -o camera-graph-overlay.dtbo camera-graph-overlay.dts
python3 - <<'PY'
from pathlib import Path
p=Path('camera-graph-overlay.dtbo').read_bytes()
Path('camera-graph-overlay.inc').write_text(','.join('0x%02x'%x for x in p))
PY
make -C "$root/build/linux-7.2" ARCH=arm64 LLVM=1 LOCALVERSION= M="$base" modules
llvm-strip --strip-debug cerro-camera-graph.ko
sha256sum cerro-camera-graph.ko
