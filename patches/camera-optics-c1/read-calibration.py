#!/usr/bin/env python3
"""Read-only Cerro IMX800 EEPROM/VCM audit while native sensor is powered.
Never send a stand-alone write message or scan unknown I2C targets.
Private EEPROM bytes stay on the handset; print only AF endpoints and hash.
"""
import ctypes,fcntl,os,hashlib,json
from pathlib import Path
class Msg(ctypes.Structure):
 _fields_=[('addr',ctypes.c_ushort),('flags',ctypes.c_ushort),('len',ctypes.c_ushort),('buf',ctypes.c_void_p)]
class Transfer(ctypes.Structure):
 _fields_=[('msgs',ctypes.POINTER(Msg)),('nmsgs',ctypes.c_uint)]
adapters=[p for p in Path('/sys/bus/i2c/devices').glob('i2c-*') if (p/'of_node').resolve().as_posix().endswith('/cci@ac15000/i2c-bus@1')]
assert len(adapters)==1,adapters
bus=adapters[0].name
sensor=Path('/sys/bus/i2c/devices')/(bus.removeprefix('i2c-')+'-0010')
assert (sensor/'driver').resolve().name=='imx800-cerro'
assert (sensor/'power/runtime_status').read_text().strip()=='active'
fd=os.open('/dev/'+bus,os.O_RDWR|os.O_CLOEXEC)
def read(addr,offset,n,addrbytes):
 assert (addr,addrbytes) in [(0x55,2),(0x0c,1)] and 1<=n<=12
 a=ctypes.create_string_buffer(offset.to_bytes(addrbytes,'big'))
 b=ctypes.create_string_buffer(n)
 msgs=(Msg*2)(Msg(addr,0,addrbytes,ctypes.addressof(a)),Msg(addr,1,n,ctypes.addressof(b)))
 fcntl.ioctl(fd,0x0707,Transfer(msgs,2))
 return b.raw
try:
 raw=b''.join(read(0x55,i,min(12,64-i),2) for i in range(0,64,12))
 path=Path('/home/user/cerro-imx800-eeprom-first64.bin')
 path.write_bytes(raw);path.chmod(0o600)
 macro=int.from_bytes(raw[13:15],'big');infinity=int.from_bytes(raw[15:17],'big')
 mode=read(0x0c,2,1,1)[0];position=int.from_bytes(read(0x0c,0,2,1),'big')
 print(json.dumps({'bus':bus,'eeprom_sha256':hashlib.sha256(raw).hexdigest(),'macro':macro,'infinity':infinity,'vcm_mode':mode,'vcm_position_reg':position,'calibration_sane':0<infinity<macro<=1023}))
finally:os.close(fd)
