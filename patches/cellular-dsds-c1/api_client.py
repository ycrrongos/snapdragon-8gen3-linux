#!/usr/bin/env python3
"""Small client and redacted verification view. Never prints subscriber values."""
import json,socket,sys

def call(action,**values):
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
  s.settimeout(100);s.connect('/run/cerro-cellular/control.sock');s.sendall((json.dumps(dict(action=action,**values))+'\n').encode())
  reply=json.loads(s.makefile('rb').readline(1024*1024))
 if not reply.get('ok'):raise RuntimeError(reply.get('error','operation failed'))
 return reply['result']

if __name__=='__main__':
 if len(sys.argv)>1 and sys.argv[1]=='select':
  print(call('select_data',slot=int(sys.argv[2])))
 else:
  v=call('status')
  print('ready',v['ready'],'data_slot',v['data_slot'],'busy',v['busy'])
  for slot in v['slots']:print('SIM',slot['slot'],'registered',slot['registered'],'number_available',bool(slot['number']),'technology',slot['technology'])
  assert v['slots'][0]['number']!=v['slots'][1]['number']
  messages=call('messages')
  print('messages',len(messages),'SMS slots',sorted(set(m['slot'] for m in messages)))
  for token in ('b0a9c6','22b949'):print('verified test message',token,'present',any(token in m['text'] for m in messages))
