import json,pathlib,struct,time
from qmi_socket import Client,QmiError,tlv,routes
from sms_pdu import submit_parts,deliver_details,normalize

class SmsStore:
    def __init__(self,state_dir):
        self.file=pathlib.Path(state_dir)/'sent.json'
        self.sent=json.loads(self.file.read_text()) if self.file.exists() else []
    def client(self,sub):
        if sub not in (1,2):raise ValueError('请选择 SIM1 或 SIM2')
        c=Client(5);c.bind(5,sub)
        if c.request(0x58)[0x10]!=bytes([sub-1]):c.close();raise RuntimeError('短信订阅绑定未确认')
        return c
    def configure_routes(self):
        for sub in (1,2):
            c=self.client(sub)
            try:
                raw=c.request(0x33)[1];n=struct.unpack_from('<H',raw)[0]
                if len(raw)!=2+n*4:raise ValueError('bad route list')
                rows=[bytearray(raw[2+4*i:6+4*i]) for i in range(n)]
                for row in rows:
                    if row[:2]==b'\0\x04':row[2:]=b'\x01\x01'
                c.request(0x32,tlv(1,struct.pack('<H',n)+b''.join(rows)))
            finally:c.close()
    def list(self):
        messages=list(self.sent);groups={}
        for sub in (1,2):
            c=self.client(sub)
            try:
                for storage in (0,1):
                    ids=set()
                    for tag in (0,1):
                        try:v=c.request(0x31,tlv(1,bytes([storage]))+tlv(0x12,b'\1')+tlv(0x11,bytes([tag])))[1]
                        except QmiError as e:
                            if e.error==47:continue
                            raise
                        count=struct.unpack_from('<I',v)[0]
                        if len(v)!=4+count*5:raise ValueError('bad SMS list')
                        ids.update(struct.unpack_from('<I',v,4+5*i)[0] for i in range(count))
                    for index in ids:
                        try:
                            v=c.request(0x22,tlv(1,struct.pack('<BI',storage,index))+tlv(0x10,b'\1'))[1]
                            if len(v)<4 or v[1]!=6 or struct.unpack_from('<H',v,2)[0]!=len(v)-4:continue
                            info=deliver_details(v[4:])
                        except (ValueError,IndexError,UnicodeError,QmiError):continue
                        item={'id':f'{sub}-{storage}-{index}','slot':sub,'direction':'in','number':info['sender'],'text':info['text'],'order':index,'time':info['time']}
                        if info['concat']:
                            ref,total,seq=info['concat'];key=(sub,info['sender'],ref,total)
                            groups.setdefault(key,{})[seq]=item
                        else:messages.append(item)
            finally:c.close()
        for (sub,origin,ref,total),parts in groups.items():
            first=parts[min(parts)].copy();first['text']=''.join(parts[i]['text'] for i in sorted(parts))
            if len(parts)!=total:first['text']+=f'\n（已收到 {len(parts)}/{total} 部分）'
            messages.append(first)
        return sorted(messages,key=lambda v:(v.get('time',0),v.get('order',0)),reverse=True)
    def send(self,sub,number,text):
        if not isinstance(text,str) or not text.strip():raise ValueError('请输入短信内容')
        parts=submit_parts(number,text);c=self.client(sub)
        try:
            for pdu in parts:c.request(0x20,tlv(1,b'\6'+struct.pack('<H',len(pdu))+pdu)+tlv(0x13,b'\0'),timeout=45)
        finally:c.close()
        self.sent.append({'id':'sent-'+str(time.time_ns()),'slot':sub,'direction':'out','number':normalize(number),'text':text,'time':time.time()})
        self.sent=self.sent[-500:]
        temporary=self.file.with_suffix('.tmp');temporary.write_text(json.dumps(self.sent,ensure_ascii=False));temporary.chmod(0o600);temporary.replace(self.file)
