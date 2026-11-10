#!/usr/bin/env python3
"""One bounded SIM2 data test; always restores the existing SIM1 NM profile."""
import argparse,ipaddress,struct,subprocess,sys,time
from qmi_socket import Client,QmiError,routes,tlv

def run(*args):return subprocess.run(args,check=True,text=True,capture_output=True).stdout

def u32(value):return struct.unpack('<I',value)[0]
def ip(value):return str(ipaddress.IPv4Address(u32(value)))
parser=argparse.ArgumentParser();parser.add_argument('--mux-id',type=int,choices=(1,2),default=2);parser.add_argument('--inspect-only',action='store_true');parser.add_argument('--explicit-endpoint',action='store_true');args=parser.parse_args()
r=routes();dsd=Client(42,r);wds=None;handle=None;link=False;nm_stopped=False;dds_changed=False;iface='cerro-sim2'
original_values=dsd.request(0x4f);original=original_values[0x10];original_type=original_values.get(0x11,struct.pack('<I',0))
assert u32(original)==1,'unexpected baseline DDS; refuse guessing rollback'
try:
 wds=Client(1,r);wds.bind(1,2)
 bound=u32(wds.request(0xb0)[0x10]);assert bound==2
 print('WDS secondary binding verified',bound,flush=True)
 run('nmcli','--wait','30','connection','down','cerro-sim1-cmnet');nm_stopped=True
 dds_changed=True
 dsd.request(0x4e,tlv(1,struct.pack('<I',2))+tlv(0x10,struct.pack('<I',1)))
 deadline=time.monotonic()+20
 while u32(dsd.request(0x4f)[0x10])!=2:
  if time.monotonic()>deadline:raise TimeoutError('DDS switch acknowledgement timeout')
  time.sleep(.25)
 print('DSD temporary DDS2 verified',flush=True)
 wds.request(0xa2,tlv(0x10,struct.pack('<II',4,1))+tlv(0x11,bytes([args.mux_id])))
 print('WDS binding after mux',u32(wds.request(0xb0)[0x10]),flush=True)
 wds.request(0x4d,tlv(1,b'\x04'))
 print('WDS IPv4 client family set; binding',u32(wds.request(0xb0)[0x10]),flush=True)
 wds.bind(1,2)
 assert u32(wds.request(0xb0)[0x10])==2,'subscription lost before data call'
 print('WDS re-bound after mux/family: secondary verified',flush=True)
 run('ip','link','add','link','rmnet_ipa0','name',iface,'type','rmnet','mux_id',str(args.mux_id),'ingress-deaggregation','on','ingress-mapv5-checksum','on','egress-mapv5-checksum','on');link=True
 run('ip','link','set','rmnet_ipa0','up');run('ip','link','set',iface,'up')
 payload=tlv(0x14,b'cmnet')+tlv(0x19,b'\x04')
 if args.explicit_endpoint:payload+=tlv(0x3b,struct.pack('<II',4,1))
 out=wds.request(0x20,payload,timeout=45)
 handle=out[1];assert len(handle)==4
 print('StartNetwork actual route',{hex(k):v.hex() for k,v in out.items() if k in (0x12,0x13)},flush=True)
 assert u32(wds.request(0xb0)[0x10])==2,'subscription lost during StartNetwork'
 print('SIM2 WDS call connected',flush=True)
 vals=wds.request(0x2d,tlv(0x10,struct.pack('<I',(1<<4)|(1<<8)|(1<<9)|(1<<13))))
 address,gateway,mask=ip(vals[0x1e]),ip(vals[0x20]),ip(vals[0x21])
 prefix=ipaddress.IPv4Network('0.0.0.0/'+mask).prefixlen
 mtu=min(1496,u32(vals.get(0x29,struct.pack('<I',1496))))
 run('ip','link','set',iface,'mtu',str(mtu))
 run('ip','address','replace',f'{address}/{prefix}','dev',iface)
 run('ip','route','replace','default','via',gateway,'dev',iface,'metric','710')
 print('SIM2 interface configured','address',address,'prefix',prefix,'gateway',gateway,'mtu',mtu,flush=True)
 if args.inspect_only:sys.exit(0)
 subprocess.run(['python3','/tmp/test-bound-data.py',iface],check=True)
 print('SIM2_BOUND_DATA_PASS',flush=True)
except QmiError as e:
 print('QMI_FAILURE',str(e),'causes',{hex(k):v.hex() for k,v in e.response.items() if k in (0x10,0x11)},flush=True)
 raise
finally:
 if wds and handle:
  try:
   stats=wds.request(0x24,tlv(1,struct.pack('<I',0x3f)))
   print('WDS packet stats',{hex(k):u32(v) for k,v in stats.items() if k!=2 and len(v)==4},flush=True)
  except Exception as e:print('stats unavailable',str(e),flush=True)
  try:wds.request(0x21,tlv(1,handle));print('SIM2 call stopped',flush=True)
  except Exception as e:print('SIM2 stop error',type(e).__name__,str(e),flush=True)
 if link:subprocess.run(['ip','link','delete',iface],check=False)
 if wds:wds.close()
 if nm_stopped:
  errors=[]
  try:
   if u32(dsd.request(0x4f)[0x10])!=u32(original):
    dsd.request(0x4e,tlv(1,original)+tlv(0x10,original_type))
   deadline=time.monotonic()+20
   while dsd.request(0x4f)[0x10]!=original:
    if time.monotonic()>deadline:raise TimeoutError('restore DDS acknowledgement timeout')
    time.sleep(.25)
   print('DDS1_RESTORED',flush=True)
  except Exception as e:errors.append(e);print('DDS_RESTORE_FAILED',type(e).__name__,str(e),flush=True)
  try:
   print(run('nmcli','--wait','45','connection','up','cerro-sim1-cmnet').strip(),flush=True)
   print('SIM1_PROFILE_RESTORED',flush=True)
  except Exception as e:errors.append(e);print('NM_RESTORE_FAILED',type(e).__name__,str(e),flush=True)
  if errors:raise RuntimeError('data restore incomplete') from errors[0]
 dsd.close()
