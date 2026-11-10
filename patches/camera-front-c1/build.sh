#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
cd "$base"
dtc -I dts -O dtb -o front-overlay.dtbo front-overlay.dts
python3 - <<'PY'
from pathlib import Path
import struct
b=Path('front-overlay.dtbo').read_bytes();assert struct.unpack_from('>I',b)[0]==0xd00dfeed
p,strings=struct.unpack_from('>II',b,8);locations=[];counts=[0]*3
while True:
 t=struct.unpack_from('>I',b,p)[0];p+=4
 if t==1:p=(b.index(0,p)+4)&~3
 elif t in (2,4):continue
 elif t==3:
  size,name=struct.unpack_from('>II',b,p);p+=8
  for at in range(p,p+size-3,4):
   marker=struct.unpack_from('>I',b,at)[0]
   if 0xca100001<=marker<=0xca100003:
    index=marker-0xca100001;counts[index]+=1;locations.append((at,index))
  p=(p+size+3)&~3
 elif t==9:break
 else:raise ValueError(t)
assert counts==[2,2,1],counts
Path('front-overlay.inc').write_text(','.join('0x%02x'%v for v in b))
Path('front-locations.inc').write_text('\n'.join('{ %d, %d },'%x for x in locations)+'\n')
print('Validated front provider locations',counts)
PY
make -C "${KERNEL_DIR:-$root/build/linux-7.2}" ARCH=arm64 LLVM=1 LOCALVERSION= M="$base" modules
llvm-strip --strip-debug ov12d2q-cerro.ko cerro-front-board.ko
sha256sum ov12d2q-cerro.ko cerro-front-board.ko
