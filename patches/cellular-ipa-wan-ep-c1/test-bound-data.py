import socket,ssl,pathlib,sys,time
iface=sys.argv[1]
def counters():
 return {k:int(pathlib.Path('/sys/class/net',iface,'statistics',k+'_bytes').read_text()) for k in ('rx','tx')}
print('before',counters(),flush=True)
failed=0
for host in ('www.baidu.com','www.qq.com'):
 try:
  addr=socket.getaddrinfo(host,443,socket.AF_INET,socket.SOCK_STREAM)[0][4]
  with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as raw:
   raw.settimeout(15)
   raw.setsockopt(socket.SOL_SOCKET,socket.SO_BINDTODEVICE,iface.encode()+b'\0')
   raw.connect(addr)
   with ssl.create_default_context().wrap_socket(raw,server_hostname=host) as conn:
    conn.sendall(('GET / HTTP/1.1\r\nHost: '+host+'\r\nUser-Agent: Cerro-Network-Test/1\r\nConnection: close\r\n\r\n').encode())
    data=b''
    while len(data)<65536:
     chunk=conn.recv(8192)
     if not chunk:break
     data+=chunk
    print(host,'status',data.split(b'\r\n',1)[0].decode(errors='replace'),'local',conn.getsockname()[0],'remote',addr[0],'bytes',len(data),flush=True)
    assert data.startswith(b'HTTP/1.1 200') or data.startswith(b'HTTP/1.1 301') or data.startswith(b'HTTP/1.1 302'),'unexpected response'
 except Exception as e:print(host,type(e).__name__,str(e),flush=True);failed+=1
print('after',counters(),flush=True)
sys.exit(bool(failed))
