#!/usr/bin/env python3
"""Export only audited byte-WRITE tables from this exact Cerro IMX800 blob.
CamX schema source is documented in the feature note; no blob is redistributed.
"""
import hashlib,struct,sys
from pathlib import Path
EXPECTED='e9d3b60d602f13c0afd4dbaff46a724293d59ed83a6fde66361893a162d92266'
data=Path(sys.argv[1]).read_bytes()
if hashlib.sha256(data).hexdigest()!=EXPECTED:raise SystemExit('unrecognized blob')
offset,size=struct.unpack_from('<II',data,0xb8);values=data[offset:offset+size]
assert len(values)==size
nodes=[]
for pos in range(0xd0,offset-55,4):
 if data[pos+40:pos+44]!=b'\xff'*4:continue
 raw=data[pos:pos+40].split(b'\0')[0]
 if not raw or not all(c==95 or 48<=c<=57 or 65<=c<=90 or 97<=c<=122 for c in raw):continue
 name=raw.decode();value,nbytes,param=struct.unpack_from('<III',data,pos+44)
 nodes.append((name,value,nbytes,param))
settings=[(i,n) for i,n in enumerate(nodes) if n[0]=='regSetting']
assert len(settings)==28
assert struct.unpack_from('<7I',values,0x2c)==(0x20,2,2,0x16,0x800,0xffffffff,2)
lines=['/* Generated from the hash-locked Cerro input; scalar byte writes only. */']
for index,name in [(15,'global'),(7,'mode7'),(1,'mode1')]:
 ni,node=settings[index];base,length=node[1:3];assert length%40==0;entries=[]
 for i in range(length//40):
  slave,datum,delay=nodes[ni+1+i*3:ni+4+i*3]
  assert [n[0] for n in (slave,datum,delay)]==['slaveAddr','registerData','delayUs']
  fields=struct.unpack_from('<10I',values,base+i*40)
  assert slave[2]==0 and fields[0]==0
  assert fields[3]==1 and fields[5:8]==(2,1,0)
  assert datum[2]==4
  address=fields[2];value=struct.unpack_from('<I',values,datum[1])[0]
  wait=struct.unpack_from('<I',values,delay[1])[0] if delay[2] else 0
  assert 0<=address<=65535 and 0<=value<=255 and wait==0
  assert address!=0x0100,'streaming is owned by the driver'
  entries.append((address,value))
 if name in ('mode7','mode1'):
  regs=dict(entries);word=lambda a:regs[a]*256+regs[a+1]
  expected=(2048,1152,5520,13188) if name=='mode7' else (4096,3072,9776,7484)
  assert (word(0x34c),word(0x34e),word(0x342),word(0x340))==expected
  assert (regs[0x30b],regs[0x30d],word(0x30e))==((2,3,499) if name=='mode7' else (2,3,500))
  resolution=next(n for n in nodes if n[0]=='resolutionData')
  assert resolution[2]==3000
  record=resolution[1]+(7 if name=='mode7' else 1)*300
  assert struct.unpack_from('<II',values,record+44)==expected[2:]
  assert struct.unpack_from('<I',values,record+60)[0]==(1368690000 if name=='mode7' else 1371430000)
  assert struct.unpack_from('<d',values,record+72)[0]==30.0
  assert struct.unpack_from('<I',values,record+88)[0]==3
  assert struct.unpack_from('<II',values,record+100)==(25,1) # settle, C-PHY

 lines.append('static const struct cci_reg_sequence imx800_'+name+'[] = {')
 lines += ['\t{ CCI_REG8(0x%04x), 0x%02x },'%e for e in entries]
 lines.append('};')
 print(name,len(entries),'writes; all delays zero',file=sys.stderr)
Path(sys.argv[2]).write_text('\n'.join(lines)+'\n')
