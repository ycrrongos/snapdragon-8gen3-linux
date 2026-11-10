from qmi_socket import Client,routes,QmiError
import struct,re
r=routes();numbers=[]
for sub in (1,2):
 d=Client(2,r);d.bind(2,sub)
 bound=struct.unpack('<I',d.request(0x55)[0x10])[0]
 number=d.request(0x24)[1].decode('ascii').strip('\0');d.close()
 assert bound==sub and re.fullmatch(r'\+?\d{7,15}',number)
 numbers.append(number)
 print('subscription',sub,'DMS verified binding',bound,'number available',True,flush=True)
 c=Client(5,r);c.bind(5,sub)
 vals=c.request(0x33)[1];count=struct.unpack_from('<H',vals)[0]
 print('subscription',sub,'WMS routes',[list(vals[2+4*i:6+4*i]) for i in range(count)],flush=True)
 for storage in (0,1):
  try:
   v=c.request(0x31,bytes([1,1,0,storage])+bytes([0x12,1,0,1])+bytes([0x11,1,0,0]))[1]
   print('subscription',sub,'storage',storage,'message count',struct.unpack_from('<I',v)[0],flush=True)
  except QmiError as e:print('subscription',sub,str(e),flush=True)
 c.close()
assert numbers[0]!=numbers[1],'bound MSISDN values are identical; refuse sending'
print('two distinct subscriber numbers verified; no message sent',flush=True)
del numbers
