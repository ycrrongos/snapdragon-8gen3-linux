"""Retry only a definite CM no-service rejection, never unknown call outcomes."""
import struct
from unittest.mock import patch
import data_session
from qmi_socket import QmiError

def failure(code=14,end=3,detail=(3,2001)):
 return QmiError(0x20,code,{0x10:struct.pack('<H',end),0x11:struct.pack('<Hh',*detail)})
class Wds:
 def __init__(self,results,subscription=2):self.results=iter(results);self.starts=0;self.subscription=subscription
 def request(self,message,*args,**kwargs):
  if message==0xb0:return {0x10:struct.pack('<I',self.subscription)}
  assert message==0x20;self.starts+=1;result=next(self.results)
  if isinstance(result,Exception):raise result
  return result
handle={1:struct.pack('<I',42)}
wds=Wds([failure(),failure(),handle])
with patch.object(data_session.time,'sleep'):
 assert data_session.DataSession().start_network(wds)==handle
assert wds.starts==3
for rejection in [failure(detail=(2,208)),failure(code=29),failure(end=1),TimeoutError('unknown call outcome')]:
 wds=Wds([rejection,handle])
 try:data_session.DataSession().start_network(wds)
 except type(rejection):pass
 else:raise AssertionError('unsafe retry')
 assert wds.starts==1
wds=Wds([failure(),handle])
try:data_session.DataSession().start_network(wds,timeout=0)
except QmiError:pass
else:raise AssertionError('ignored deadline')
assert wds.starts==1
wds=Wds([handle],subscription=255)
try:data_session.DataSession().start_network(wds)
except RuntimeError:pass
else:raise AssertionError('unbound subscription accepted')
assert wds.starts==0
print('CM no-service recovery, permanent rejection, timeout, binding and deadline gates passed')
