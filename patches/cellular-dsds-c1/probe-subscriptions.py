#!/usr/bin/env python3
import re,struct
from qmi_socket import Client,routes,QmiError
r=routes()
for sub in (1,2):
    for svc,label in ((3,'NAS'),(2,'DMS'),(5,'WMS')):
        c=Client(svc,r)
        try:
            c.bind(svc,sub)
            print('subscription',sub,label,'bind OK',flush=True)
            if svc==3:
                v=c.request(0x24).get(1,b'')
                print('subscription',sub,'serving',dict(zip(('registration','cs','ps','network','interfaces'),v[:5])),'radios',list(v[5:]),flush=True)
            if svc==2:
                raw=c.request(0x24).get(1,b'')
                number=raw.decode('ascii',errors='ignore').strip('\0')
                print('subscription',sub,'MSISDN present',bool(re.fullmatch(r'\+?\d{7,15}',number)),'length',len(number),flush=True)
                del raw,number
            if svc==5:
                for message in (0x48,0x4a):
                    try:
                        vals=c.request(message)
                        print('subscription',sub,'WMS GET',hex(message),'tlv shapes',{hex(k):len(v) for k,v in vals.items()},flush=True)
                    except QmiError as e:print('subscription',sub,str(e),flush=True)
        except Exception as e:print('subscription',sub,label,type(e).__name__,str(e),flush=True)
        finally:c.close()
