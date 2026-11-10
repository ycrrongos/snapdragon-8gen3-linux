#!/usr/bin/env python3
"""Explicit two-message test between the user's two verified local SIMs only."""
import argparse,secrets,struct,time
from qmi_socket import Client,QmiError,routes,tlv
from sms_pdu import normalize,submit,deliver

def unread_indexes(c,storage):
 result=set()
 for tag in (0,1):
  try:v=c.request(0x31,tlv(1,bytes([storage]))+tlv(0x12,b'\x01')+tlv(0x11,bytes([tag])))[1]
  except QmiError as e:
   if e.error==47:continue # This firmware returns InvalidIndex for empty tag lists.
   raise
  count=struct.unpack_from('<I',v)[0]
  if len(v)!=4+count*5:raise ValueError('invalid SMS list size')
  result.update(struct.unpack_from('<I',v,4+i*5)[0] for i in range(count))
 return result

def read(c,storage,index):
 v=c.request(0x22,tlv(1,struct.pack('<BI',storage,index))+tlv(0x10,b'\x01'))[1]
 if len(v)<4 or v[1]!=6:raise ValueError('unsupported SMS format')
 size=struct.unpack_from('<H',v,2)[0]
 if len(v)!=size+4:raise ValueError('invalid SMS record size')
 return deliver(v[4:])

def setup_receiver(c):
 original=c.request(0x33)[1]
 n=struct.unpack_from('<H',original)[0]
 if len(original)!=2+4*n:raise ValueError('bad SMS route list')
 records=[bytearray(original[2+4*i:6+4*i]) for i in range(n)]
 changed=False
 for row in records:
  if row[:2]==b'\0\x04' and row[2:]!=b'\x01\x01':
   row[2:]=b'\x01\x01';changed=True # ordinary class: ME store+notify
 if changed:c.request(0x32,tlv(1,struct.pack('<H',n)+b''.join(records)))
 c.request(1,tlv(0x10,b'\x01'))
 return {(storage,index) for storage in (0,1) for index in unread_indexes(c,storage)}

def main():
    p=argparse.ArgumentParser();p.add_argument('--send-mutual-tests',action='store_true');p.add_argument('--direction',choices=('both','1to2','2to1'),default='both');a=p.parse_args()
    if not a.send_mutual_tests:p.error('explicit --send-mutual-tests required')
    r=routes();numbers={};clients={}
    try:
     for sub in (1,2):
      c=Client(2,r)
      try:
       c.bind(2,sub);assert struct.unpack('<I',c.request(0x55)[0x10])[0]==sub
       number=c.request(0x24)[1].decode('ascii').strip('\0')
       numbers[sub]=normalize(number)
      finally:c.close()
     assert numbers[1]!=numbers[2],'identical numbers; refuse sending'
     for sub in (1,2):
      c=Client(5,r);c.bind(5,sub);clients[sub]=c
     baseline={sub:setup_receiver(c) for sub,c in clients.items()}
     token=secrets.token_hex(3)
     for sender,receiver in ({'both':((1,2),(2,1)),'1to2':((1,2),),'2to1':((2,1),)}[a.direction]):
      text=f'Linux 短信测试 {sender}>{receiver} {token}'
      pdu=submit('+'+numbers[receiver],text)
      # Never retry this operation automatically, even on a timeout.
      vals=clients[sender].request(0x20,tlv(1,bytes([6])+struct.pack('<H',len(pdu))+pdu)+tlv(0x13,b'\0'),timeout=45)
      print('SMS',f'{sender}>{receiver}',token,'submitted',True,flush=True)
      deadline=time.monotonic()+65;matched=False;seen=set(baseline[receiver])
      while time.monotonic()<deadline and not matched:
       c=clients[receiver]
       for storage in (0,1):
        for index in unread_indexes(c,storage):
         if (storage,index) in seen:continue
         seen.add((storage,index))
         try:origin,body=read(c,storage,index)
         except (QmiError,ValueError,UnicodeError):continue
         if origin==numbers[sender] and body==text:
          print('SMS',f'{sender}>{receiver}',token,'RECEIVED verified sender+UCS2 content',flush=True)
          matched=True;break
        if matched:break
       if c.indications:
        for mid,items in c.indications:
         print('receiver',receiver,'indication',hex(mid),'shapes',{hex(k):len(v) for k,v in items.items()},flush=True)
         if mid==1 and 0x11 in items:
          data=items[0x11]
          if len(data)>=8 and data[5]==6:
           try:origin,body=deliver(data[8:])
           except (ValueError,UnicodeError,IndexError):continue
           if origin==numbers[sender] and body==text:matched=True;print('SMS',f'{sender}>{receiver}',token,'RECEIVED transfer verified',flush=True)
        c.indications.clear()
       if not matched:time.sleep(2)
      if not matched:raise TimeoutError(f'SMS {sender}>{receiver} not observed; do not resend blindly')
     print('REQUESTED_DIRECTIONS_VERIFIED',a.direction,token,flush=True)
    finally:
     for c in clients.values():c.close()
     numbers.clear()

if __name__=='__main__':main()
