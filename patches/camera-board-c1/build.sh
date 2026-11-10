#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
cd "$base"
dtc -I dts -O dtb -o camera-board-overlay.dtbo camera-board-overlay.dts
python3 - <<'PY'
from pathlib import Path
import struct
b=Path('camera-board-overlay.dtbo').read_bytes()
assert struct.unpack_from('>I',b)[0]==0xd00dfeed
p,strings=struct.unpack_from('>II',b,8)
locations=[]; counts=[0]*6
# Parse PROP values only; never patch a coincidental byte pattern elsewhere.
while True:
 token=struct.unpack_from('>I',b,p)[0];p+=4
 if token==1:
  p=(b.index(0,p)+4)&~3
 elif token==2 or token==4:continue
 elif token==3:
  size,name=struct.unpack_from('>II',b,p);p+=8
  for off in range(p,p+size-3,4):
   marker=struct.unpack_from('>I',b,off)[0]
   if 0xca000001<=marker<=0xca000006:
    binding=marker-0xca000001;locations.append((off,binding));counts[binding]+=1
  p=(p+size+3)&~3
 elif token==9:break
 else:raise ValueError(token)
assert counts==[2,2,1,1,1,1],counts
Path('camera-board-overlay.inc').write_text(','.join('0x%02x'%x for x in b))
Path('camera-board-locations.inc').write_text('\n'.join('{ %d, %d },'%x for x in locations)+'\n')
print('Typed provider/OTP locations',locations)
PY
make -C "${KERNEL_DIR:-$root/build/linux-7.2}" ARCH=arm64 LLVM=1 LOCALVERSION= M="$base" modules
llvm-strip --strip-debug cerro-camera-board.ko
sha256sum cerro-camera-board.ko
