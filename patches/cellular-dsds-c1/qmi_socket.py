"""Independent QRTR QMI clients. Does not share ModemManager client sockets."""
import socket,struct,subprocess,time

def tlv(tag,value):
    return struct.pack('<BH',tag,len(value))+value

def parse_tlvs(data):
    result={};pos=0
    while pos<len(data):
        if len(data)-pos<3:raise ValueError('truncated TLV header')
        tag,size=struct.unpack_from('<BH',data,pos);pos+=3
        if size>len(data)-pos:raise ValueError('truncated TLV body')
        if tag in result:raise ValueError('duplicate TLV')
        result[tag]=data[pos:pos+size];pos+=size
    return result

def routes():
    out=subprocess.check_output(['qrtr-lookup'],text=True)
    found={}
    for line in out.splitlines():
        cols=line.split()
        if len(cols)<5 or not all(x.isdigit() for x in cols[:5]):continue
        service,version,instance,node,port=map(int,cols[:5])
        if instance==0 and node==0:found[service]=(node,port)
    return found

class QmiError(Exception):
    def __init__(self,message,error,response=None):
        self.message=message;self.error=error;self.response=response or {}
        super().__init__(f'QMI message 0x{message:04x} error={error}')

class Client:
    def __init__(self,service,route_map=None):
        self.sock=socket.socket(socket.AF_QIPCRTR,socket.SOCK_DGRAM)
        self.sock.connect((route_map or routes())[service]);self.tx=0
        self.indications=[]
    def close(self):self.sock.close()
    def request(self,message,payload=b'',timeout=10):
        self.tx=(self.tx+1)%65536 or 1
        self.sock.send(struct.pack('<BHHH',0,self.tx,message,len(payload))+payload)
        deadline=time.monotonic()+timeout
        while True:
            remain=deadline-time.monotonic()
            if remain<=0:raise TimeoutError(f'QMI 0x{message:04x} timeout')
            self.sock.settimeout(remain)
            data=self.sock.recv(65536)
            if len(data)<7:continue
            flags,tx,mid,size=struct.unpack_from('<BHHH',data)
            if size!=len(data)-7:raise ValueError('QMI payload size mismatch')
            if flags==4:
                self.indications.append((mid,parse_tlvs(data[7:])));continue
            if flags!=2 or tx!=self.tx or mid!=message:continue
            vals=parse_tlvs(data[7:])
            if len(vals.get(2,b''))!=4:raise ValueError('missing QMI result')
            status,error=struct.unpack('<HH',vals[2])
            if status or error:raise QmiError(message,error,vals)
            return vals
    def bind(self,service,subscription):
        # Public Gobi API NAS/WMS use uint8 zero-based; DMS/WDS uint32 one-based.
        msg,payload={3:(0x45,bytes([subscription-1])),
                     5:(0x4c,bytes([subscription-1])),
                     2:(0x54,struct.pack('<I',subscription)),
                     1:(0xaf,struct.pack('<I',subscription))}[service]
        self.request(msg,tlv(1,payload))
