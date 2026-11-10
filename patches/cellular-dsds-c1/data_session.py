"""Own only the secondary WDS call; the primary remains NetworkManager managed."""
import ipaddress,pathlib,struct,subprocess,time
from qmi_socket import Client,QmiError,tlv

def run(*args):return subprocess.run(args,check=True,text=True,capture_output=True,timeout=60).stdout

def u32(value):return struct.unpack('<I',value)[0]
def addr(value):return str(ipaddress.IPv4Address(u32(value)))

class DataSession:
    iface='cerro-sim2'
    def __init__(self):self.wds=None;self.handle=None;self.link=False
    def dds(self,sub):
        c=Client(42)
        try:
            if u32(c.request(0x4f)[0x10])!=sub:
                c.request(0x4e,tlv(1,struct.pack('<I',sub))+tlv(0x10,struct.pack('<I',1 if sub==2 else 0)))
            deadline=time.monotonic()+20
            while u32(c.request(0x4f)[0x10])!=sub:
                if time.monotonic()>deadline:raise TimeoutError('data subscription switch not acknowledged')
                time.sleep(.25)
        finally:c.close()
    def wait_packet_service(self,subscription,timeout=90):
        client=Client(3)
        try:
            client.bind(3,subscription)
            deadline=time.monotonic()+timeout;previous=None
            while True:
                value=client.request(0x24).get(1,b'')
                state=(value[0],value[2]) if len(value)>=3 else None
                if state==(1,1):return
                if state!=previous:
                    print('cerro-cellular: waiting for subscription',subscription,'registration/PS',state,flush=True);previous=state
                if time.monotonic()>deadline:raise TimeoutError('selected subscription packet service not attached')
                time.sleep(.5)
        finally:client.close()
    def initialize_data_port(self):
        # Same IPA DPM/WDA dependency as MMPortQmi setup_data_format; registration
        # alone does not initialize it. Read capabilities, never guess endpoints.
        base=pathlib.Path('/sys/devices/platform/soc@0/3f40000.ipa')
        tx=int((base/'modem/tx_endpoint_id').read_text());rx=int((base/'modem/rx_endpoint_id').read_text())
        if not (0<tx<256 and 0<rx<256):raise RuntimeError('invalid IPA hardware endpoints')
        protocols={'MAPv5':9,'MAPv4':8,'none':5,'NONE':5}
        formats=[(base/'feature'/name).read_text().strip() for name in ('tx_offload','rx_offload')]
        if any(value not in protocols for value in formats):raise RuntimeError('unsupported IPA data format')
        ul,dl=map(protocols.get,formats)
        dpm=Client(47)
        try:
            # Modem RX is IPA TX, modem TX is IPA RX. uint8 count + four uint32.
            dpm.request(0x20,tlv(0x11,struct.pack('<BIIII',1,4,1,tx,rx)))
        finally:dpm.close()
        wda=Client(26)
        try:
            endpoint=struct.pack('<II',4,1)
            current=wda.request(0x21,tlv(0x10,endpoint))
            expected={0x11:2,0x12:ul,0x13:dl}
            if any(u32(current.get(key,b'\0'*4))!=value for key,value in expected.items()):
                payload=b''.join(tlv(key,struct.pack('<I',value)) for key,value in expected.items())
                # ModemManager's IPA aggregation limits (not the qmi_wwan limit).
                payload+=tlv(0x15,struct.pack('<I',32))+tlv(0x16,struct.pack('<I',32768))+tlv(0x17,endpoint)
                wda.request(0x20,payload)
            actual=wda.request(0x21,tlv(0x10,endpoint))
            if any(u32(actual.get(key,b'\0'*4))!=value for key,value in expected.items()):
                raise RuntimeError('WDA data format not acknowledged')
            print('cerro-cellular: IPA data port initialized; UL/DL formats',ul,dl,flush=True)
        finally:wda.close()
    def start_network(self,client,timeout=90):
        # NAS PS attachment precedes CM data availability during initial attach.
        # Retry only an explicit no-call/no-service response, never a timeout or
        # an APN/authentication rejection whose outcome or cause differs.
        deadline=time.monotonic()+timeout;waiting=False
        while True:
            if u32(client.request(0xb0)[0x10])!=2:raise RuntimeError('WDS subscription lost before connect')
            try:
                return client.request(0x20,tlv(0x14,b'cmnet')+tlv(0x19,b'\4')+tlv(0x3b,struct.pack('<II',4,1)),timeout=min(45,max(1,deadline-time.monotonic())))
            except QmiError as exc:
                raw=exc.response.get(0x10,b'');verbose=exc.response.get(0x11,b'')
                reason=struct.unpack('<H',raw)[0] if len(raw)==2 else None
                detail=struct.unpack('<Hh',verbose) if len(verbose)==4 else None
                transient=exc.error==14 and reason==3 and detail==(3,2001)
                if not waiting or not transient:
                    print('cerro-cellular: WDS call rejected; QMI',exc.error,'end',reason,'verbose',detail,flush=True)
                if not transient or time.monotonic()>=deadline:raise
                if not waiting:print('cerro-cellular: waiting for CM packet service availability',flush=True)
                waiting=True
                time.sleep(.5)
    def connect(self):
        if self.handle:return
        try:
            self.dds(2)
            self.wait_packet_service(2)
            self.initialize_data_port()
            c=Client(1);self.wds=c
            c.request(0xa2,tlv(0x10,struct.pack('<II',4,1))+tlv(0x11,b'\1'))
            c.request(0x4d,tlv(1,b'\4'))
            c.bind(1,2)
            assert u32(c.request(0xb0)[0x10])==2,'WDS subscription binding not verified'
            base=pathlib.Path('/sys/devices/platform/soc@0/3f40000.ipa/feature')
            tx=(base/'tx_offload').read_text().strip();rx=(base/'rx_offload').read_text().strip()
            flags=['ingress-deaggregation','on']
            for direction,value in [('ingress',rx),('egress',tx)]:
                if value.startswith('MAPv5'):flags += [direction+'-mapv5-checksum','on']
                elif value.startswith('MAPv4'):flags += [direction+'-mapv4-checksum','on']
                elif value not in ('none','NONE',''):raise RuntimeError('unsupported IPA checksum format')
            run('ip','link','add','link','rmnet_ipa0','name',self.iface,'type','rmnet','mux_id','1',*flags);self.link=True
            run('ip','link','set','rmnet_ipa0','up');run('ip','link','set',self.iface,'up')
            out=self.start_network(c)
            self.handle=out[1]
            assert u32(c.request(0xb0)[0x10])==2,'WDS subscription lost during connect'
            v=c.request(0x2d,tlv(0x10,struct.pack('<I',(1<<4)|(1<<8)|(1<<9)|(1<<13))))
            address,gateway,mask=addr(v[0x1e]),addr(v[0x20]),addr(v[0x21])
            prefix=ipaddress.IPv4Network('0.0.0.0/'+mask).prefixlen
            mtu=min(1496,u32(v.get(0x29,struct.pack('<I',1496))))
            run('ip','link','set',self.iface,'mtu',str(mtu))
            dns=[addr(v[k]) for k in (0x15,0x16) if k in v]
            profile='cerro-sim2-ip'
            exists=subprocess.run(['nmcli','-t','connection','show',profile],capture_output=True).returncode==0
            if not exists:run('nmcli','connection','add','type','generic','ifname',self.iface,'con-name',profile,'connection.autoconnect','no','ipv4.method','disabled','ipv6.method','disabled')
            run('nmcli','connection','modify',profile,'ipv4.method','manual','ipv4.addresses',f'{address}/{prefix}','ipv4.gateway',gateway,'ipv4.dns',','.join(dns),'ipv4.route-metric','700','ipv4.ignore-auto-dns','yes','ipv6.method','disabled')
            run('nmcli','device','set',self.iface,'managed','yes')
            run('nmcli','--wait','30','connection','up',profile,'ifname',self.iface)
        except Exception:
            self.close();raise
    def close(self):
        error=None
        if self.link:subprocess.run(['nmcli','--wait','15','connection','down','cerro-sim2-ip'],capture_output=True,timeout=20)
        if self.wds:
            try:
                if self.handle:self.wds.request(0x21,tlv(1,self.handle))
            except Exception as exc:error=exc
            finally:self.wds.close();self.wds=None;self.handle=None
        if self.link:
            subprocess.run(['ip','link','delete',self.iface],capture_output=True);self.link=False
        try:self.dds(1)
        except Exception as exc:error=error or exc
        if error:raise error
