#!/usr/bin/env python3
"""Bounded contrast experiment, not the daily camera or an autofocus claim.
Only stock AK7316 volatile mode/position registers; per-unit OTP endpoints.
Own one continuous RAW stream so power never vanishes between focus settings.
"""
import ctypes,fcntl,os,subprocess,time,json,signal,select,sys,struct
from pathlib import Path
from array import array
class Msg(ctypes.Structure):
 _fields_=[('addr',ctypes.c_ushort),('flags',ctypes.c_ushort),('len',ctypes.c_ushort),('buf',ctypes.c_void_p)]
class Transfer(ctypes.Structure):
 _fields_=[('msgs',ctypes.POINTER(Msg)),('nmsgs',ctypes.c_uint)]
parents=[p for p in Path('/sys/bus/i2c/devices').glob('i2c-*') if (p/'of_node').resolve().as_posix().endswith('/cci@ac15000/i2c-bus@1')]
assert len(parents)==1
bus=parents[0].name; sensor=Path('/sys/bus/i2c/devices')/(bus[4:]+'-0010')
assert (sensor/'driver').resolve().name=='imx800-cerro'
assert (sensor/'power/runtime_status').read_text().strip()=='suspended'
native='--v4l2' in sys.argv
vcm_device=sensor.parent/(bus[4:]+'-000c')
if native:
 assert (vcm_device/'driver').resolve().name=='ak7316-cerro'
else:
 assert not (vcm_device/'driver').exists(), 'VCM already owned'
out=Path('/home/user/cerro-focus-v4l2' if native else '/home/user/cerro-focus-sweep');out.mkdir(exist_ok=False)
log=(out/'stream.log').open('wb');size=2048*1152*5//4
subprocess.run(['v4l2-ctl','-d','/dev/v4l-subdev28','--set-ctrl=exposure=13140,analogue_gain=12000'],check=True)
stream=subprocess.Popen(['v4l2-ctl','-d','/dev/video0','--stream-mmap=4','--stream-to=-'],stdout=subprocess.PIPE,stderr=log)
fd=os.open('/dev/'+bus,os.O_RDWR|os.O_CLOEXEC);active=False;position=None;lensfd=None;deadline=time.monotonic()+40
signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(TimeoutError('terminated')))
def xfer(addr,prefix,n=0):
 assert addr in (0x55,0x0c)
 a=ctypes.create_string_buffer(prefix)
 if n:
  assert 1<=n<=12
  b=ctypes.create_string_buffer(n)
  msgs=(Msg*2)(Msg(addr,0,len(prefix),ctypes.addressof(a)),Msg(addr,1,n,ctypes.addressof(b)))
 else:
  assert addr==0x0c and ((len(prefix)==2 and prefix in (b'\x02\x40',b'\x02\x00')) or (len(prefix)==3 and prefix[0]==0))
  msgs=(Msg*1)(Msg(addr,0,len(prefix),ctypes.addressof(a)))
 fcntl.ioctl(fd,0x0707,Transfer(msgs,len(msgs)))
 return b.raw if n else b''
def frame():
 data=bytearray()
 while len(data)<size:
  left=deadline-time.monotonic()
  if left<=0 or not select.select([stream.stdout],[],[],left)[0]:raise TimeoutError('RAW stream deadline')
  chunk=os.read(stream.stdout.fileno(),size-len(data))
  if not chunk:raise RuntimeError('RAW stream ended early')
  data.extend(chunk)
 return data
def move(target):
 global position
 assert infinity<=target<=macro
 steps=[target] if position is None else list(range(position,target,16 if target>position else -16))+[target]
 if native:
  fcntl.ioctl(lensfd,0xc008561c,struct.pack('Ii',0x009a090a,target))
  position=target
  steps=[]
 for p in steps:
  xfer(0x0c,b'\x00'+(p<<6).to_bytes(2,'big'));position=p;time.sleep(.001)
 readback=int.from_bytes(xfer(0x0c,b'\x00',2),'big')
 assert readback>>6==target,(target,readback)
def metric(raw):
 # Same-colour green pixels in central 1024x576 ROI, subsampled by4.
 rows=[];total=0;count=0
 for y in range(288,864,4):
  row=[]
  for x in range(512,1536,4):
   xx=x+1;off=y*2560+(xx//4)*5
   value=(raw[off+xx%4]<<2)|((raw[off+4]>>(2*(xx%4)))&3)
   row.append(value);total+=max(0,value-64);count+=1
  rows.append(row)
 energy=0;n=0
 for y in range(1,len(rows)-1):
  for x in range(1,len(rows[y])-1):
   lap=4*rows[y][x]-rows[y][x-1]-rows[y][x+1]-rows[y-1][x]-rows[y+1][x]
   energy+=lap*lap;n+=1
 mean=total/count
 return energy/n/max(1,mean*mean),mean
try:
 frame() # Starts sensor power before any control I/O.
 assert (sensor/'power/runtime_status').read_text().strip()=='active'
 otp=xfer(0x55,b'\x00\x0d',4)
 macro=int.from_bytes(otp[:2],'big');infinity=int.from_bytes(otp[2:],'big')
 assert 0<infinity<macro<=1023
 if native:
  subdevices=list((vcm_device/'video4linux').glob('v4l-subdev*'));assert len(subdevices)==1
  lensfd=os.open('/dev/'+subdevices[0].name,os.O_RDWR|os.O_CLOEXEC)
 else:
  xfer(0x0c,b'\x02\x40');time.sleep(.001)
  xfer(0x0c,b'\x02\x00');time.sleep(.001)
 active=True
 results=[]
 def measure(p):
  move(p)
  for _ in range(8):frame()
  raw=frame();score,mean=metric(raw)
  (out/('focus-%04d.raw'%p)).write_bytes(raw)
  item={'position':p,'score':score,'mean_above_black':mean};results.append(item);print(json.dumps(item),flush=True)
 coarse=sorted(set([infinity,macro]+list(range(infinity,macro+1,104))))
 for p in coarse:measure(p)
 best=max(results,key=lambda r:r['score'])['position']
 for p in range(max(infinity,best-64),min(macro,best+64)+1,16):
  if p not in coarse:measure(p)
 best=max(results,key=lambda r:r['score'])['position'];measure(best)
 (out/'results.json').write_text(json.dumps({'infinity':infinity,'macro':macro,'best':best,'frames':results},indent=2))
 print(json.dumps({'best':best,'out':str(out)}),flush=True)
finally:
 try:
  if active and (sensor/'power/runtime_status').read_text().strip()=='active':
   move(infinity)
   if not native:xfer(0x0c,b'\x02\x40')
 finally:
  if lensfd is not None:os.close(lensfd)
  os.close(fd);stream.send_signal(signal.SIGINT)
  try:stream.wait(timeout=3)
  except subprocess.TimeoutExpired:stream.kill();stream.wait()
  stream.stdout.close();log.close()
 print('sensor_after='+ (sensor/'power/runtime_status').read_text().strip(),flush=True)
