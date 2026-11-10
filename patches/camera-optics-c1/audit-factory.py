#!/usr/bin/env python3
"""Hash-locked interface facts, not a redistributable vendor driver/blob.
Packed BinaryParameter root records and leaf references are checked, including
16/32-bit fields. Never use the old heuristic register parser for hardware I/O.
"""
import hashlib,json,struct,sys
from pathlib import Path
b=Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(b).hexdigest()=='e9d3b60d602f13c0afd4dbaff46a724293d59ed83a6fde66361893a162d92266'
o,n=struct.unpack_from('<II',b,0xb8);v=b[o:o+n]
assert len(v)==n
assert b[0x184:0x184+14]==b'actuatorDriver'
assert struct.unpack_from('<II',b,0x1b0)==(0x2ce,142)
assert struct.unpack_from('<H',v,0x2ea)[0]==0x18
assert struct.unpack_from('<H',v,0x2fc)[0]==10
assert v[68706:68713]==b'ak7316\0'
assert struct.unpack_from('<9I',v,68838)==(1,2,0,0,1,0,0,0,6)
# Init records: optional slave absent; only register2 byteWRITE, no firmware/NVM.
for base,datum in [(68874,64),(68914,0)]:
 fields=struct.unpack_from('<10I',v,base)
 assert fields[0]==0 and fields[2]==2 and fields[3]==1 and fields[5:8]==(1,1,0)
 leaf=fields[4]
 # Leaf records are 60B; the parameter ID indexes the full binary table.
 rec=0xd0+(leaf-1)*60
 assert b[rec:rec+12]==b'registerData'
 at,size=struct.unpack_from('<II',b,rec+44)
 assert size==4 and struct.unpack_from('<I',v,at)[0]==datum
assert struct.unpack_from('<H',v,0x370)[0]==0xaa
assert struct.unpack_from('<II',v,0x3de)==(1,0) # available, BIG
assert struct.unpack_from('<III',v,0x3e6)==(13,0xffff,0)
assert struct.unpack_from('<III',v,0x3f2)==(15,0xffff,0)
print(json.dumps({'actuator':'ak7316','cci':'CCI0/master1','i2c_7bit':12,'position_register':0,'dac_bits':10,'position_shift':6,'init':[[2,64],[2,0]],'eeprom_7bit':85,'af_macro_offset':13,'af_infinity_offset':15,'endian':'big'},indent=2))
