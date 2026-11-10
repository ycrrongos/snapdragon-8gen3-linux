#!/usr/bin/env python3
"""Export audited OV12D2Q scalar byte writes from the hash-locked Cerro module.
No vendor implementation, EEPROM, OIS, lens or flash data is exported.
"""
from pathlib import Path
import hashlib,struct,sys
EXPECTED='8480ffe397f8a4b191e2b4c616a529ae590bbd5b9062c1b853f08c8e78d5de3b'
b=Path(sys.argv[1]).read_bytes();assert hashlib.sha256(b).hexdigest()==EXPECTED
o,size=struct.unpack_from('<II',b,0xb8);v=b[o:o+size];assert len(v)==size
nodes=[]
for p in range(0xd0,o-55,60):
 assert struct.unpack_from('<I',b,p+40)[0] in (0,0xffffffff)
 name=b[p:p+40].split(b'\0')[0].decode();at,length,param=struct.unpack_from('<III',b,p+44)
 nodes.append((name,at,length,param))
assert struct.unpack_from('<7I',v,0x2c)==(0x20,2,2,0x300b,0x1441,0xffffffff,3)
settings=[n for n in nodes if n[0]=='regSetting'];assert len(settings)==9
out=['/* SPDX-License-Identifier: GPL-2.0-only */','/* Audited scalar sensor register values; no device calibration. */']
for index,name in [(6,'global'),(0,'mode0'),(1,'mode1')]:
 node=settings[index];assert node[2]%40==0;table=[]
 for i in range(node[2]//40):
  f=struct.unpack_from('<10I',v,node[1]+40*i)
  assert f[0]==0 and f[3]==1 and f[5:8]==(2,1,0)
  leaf=nodes[f[4]-1];assert leaf[0]=='registerData' and leaf[2]==4
  val=struct.unpack_from('<I',v,leaf[1])[0]
  if f[8]:
   delay=nodes[f[9]-1];assert delay[0]=='delayUs' and delay[2]==4
   assert struct.unpack_from('<I',v,delay[1])[0]==0
  assert 0<=f[2]<=65535 and 0<=val<=255
  assert f[2]!=0x100,'stream owned by driver'
  if f[2]==0x103:
   assert name=='global' and i==0 and val==1
   continue # driver issues this reset and waits before programming global
  table.append((f[2],val))
 if name.startswith('mode'):
  regs=dict(table);word=lambda a:regs[a]*256+regs[a+1]
  assert (word(0x3808),word(0x380a),word(0x380c),word(0x380e))==((3840,2160,540,5555) if index==0 else (1920,1080,540,5555))
 out.append('static const struct cci_reg_sequence ov12d2q_'+name+'[] = {')
 out+=[' { CCI_REG8(0x%04x), 0x%02x },'%x for x in table];out.append('};')
 print(name,len(table),'byte writes')
Path(sys.argv[2]).write_text('\n'.join(out)+'\n')
