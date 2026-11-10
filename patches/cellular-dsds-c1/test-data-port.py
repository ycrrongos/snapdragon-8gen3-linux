"""Decode real port-setup requests against libqmi DPM/WDA wire layouts."""
import pathlib,struct,tempfile
from unittest.mock import patch
import data_session
from qmi_socket import parse_tlvs

pack=lambda value:struct.pack('<I',value)
class Endpoint:
 def __init__(self,service):self.service=service;self.closed=False
 def request(self,message,payload=b''):
  fields=parse_tlvs(payload);requests.append((self.service,message,fields))
  if self.service==47:
   assert message==0x20
   assert struct.unpack('<BIIII',fields[0x11])==(1,4,1,2,24)
   return {}
  if message==0x21:
   assert struct.unpack('<II',fields[0x10])==(4,1)
   return dict(current)
  assert message==0x20
  assert {key:struct.unpack('<I',fields[key])[0] for key in (0x11,0x12,0x13,0x15,0x16)}=={0x11:2,0x12:9,0x13:9,0x15:32,0x16:32768}
  assert struct.unpack('<II',fields[0x17])==(4,1)
  current.update({key:fields[key] for key in (0x11,0x12,0x13)})
  return {}
 def close(self):self.closed=True
realpath=pathlib.Path
with tempfile.TemporaryDirectory() as directory:
 base=realpath(directory)
 for name,value in {'modem/tx_endpoint_id':'2','modem/rx_endpoint_id':'24','feature/tx_offload':'MAPv5','feature/rx_offload':'MAPv5'}.items():
  p=base/name;p.parent.mkdir(exist_ok=True);p.write_text(value)
 clients=[];requests=[];current={0x11:pack(2),0x12:pack(0),0x13:pack(0)}
 def client(service):
  c=Endpoint(service);clients.append(c);return c
 with patch.object(data_session.pathlib,'Path',return_value=base),patch.object(data_session,'Client',side_effect=client):
  data_session.DataSession().initialize_data_port()
  first=len(requests)
  data_session.DataSession().initialize_data_port()
 assert len([r for r in requests if r[:2]==(26,0x20)])==1
 assert all(c.closed for c in clients)
 assert requests[first][0]==47
print('DPM endpoint direction, WDA request/readback and initialized-port reuse passed')
