#!/usr/bin/env python3
"""Disposable bridge/veth + TCP/UDP NAT + DHCP CHECKSUM test in private namespaces.

Invoke under unshare --mount --pid --net --fork --mount-proc as root. No route,
firewall or interface in the phone's original network namespace is changed.
"""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys

assert os.geteuid()==0 and os.getpid()==1,'Must be PID1 of an isolated namespace'
NS=('wd-client','wd-router','wd-server');server=None

def run(*args):
    try:
        return subprocess.run(args,check=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=12).stdout
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f'{args}: {e.stderr.strip()}') from e

def ip(*args):return run('ip',*args)
def inside(name,*args):return run('ip','netns','exec',name,*args)
def stop_signal(*_):raise RuntimeError('probe terminated')
signal.signal(signal.SIGTERM,stop_signal)
signal.signal(signal.SIGINT,stop_signal)
Path('/run/netns').mkdir(exist_ok=True)
run('mount','-t','tmpfs','tmpfs','/run/netns')
created=[]
try:
    for name in NS:
        ip('netns','add',name);created.append(name)
        inside(name,'ip','link','set','lo','up')
    for left,right,leftns,rightns in [('c0','r0',NS[0],NS[1]),('r1','s0',NS[1],NS[2])]:
        ip('link','add',left,'type','veth','peer','name',right)
        ip('link','set',left,'netns',leftns);ip('link','set',right,'netns',rightns)
        inside(leftns,'ip','link','set',left,'up');inside(rightns,'ip','link','set',right,'up')
    inside(NS[1],'ip','link','add','brtest','type','bridge')
    inside(NS[1],'ip','link','set','r0','master','brtest')
    inside(NS[1],'ip','link','set','brtest','up')
    for name,dev,addr in [(NS[0],'c0','192.0.2.2/24'),(NS[1],'brtest','192.0.2.1/24'),(NS[1],'r1','198.51.100.1/24'),(NS[2],'s0','198.51.100.2/24')]:
        inside(name,'ip','addr','add',addr,'dev',dev)
    inside(NS[0],'ip','route','add','default','via','192.0.2.1')
    inside(NS[1],'sysctl','-w','net.ipv4.ip_forward=1')
    inside(NS[1],'iptables-legacy','-t','nat','-A','POSTROUTING','-s','192.0.2.0/24','-o','r1','-j','MASQUERADE')
    inside(NS[1],'iptables-legacy','-t','mangle','-A','POSTROUTING','-o','brtest','-p','udp','--dport','68','-j','CHECKSUM','--checksum-fill')
    server_code="""
import socket
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('198.51.100.2',18080));s.listen(1);s.settimeout(20)
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.bind(('198.51.100.2',1068));u.settimeout(20)
print('ready',flush=True)
c,peer=s.accept();c.recv(4096);body=peer[0].encode();c.sendall(b'HTTP/1.0 200 OK\\r\\nContent-Length: '+str(len(body)).encode()+b'\\r\\n\\r\\n'+body);c.close();s.close()
data,peer=u.recvfrom(100);assert data==b'checksum-test';u.sendto(peer[0].encode(),peer);u.close()
"""
    server=subprocess.Popen(['ip','netns','exec',NS[2],sys.executable,'-u','-c',server_code],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert select.select([server.stdout],[],[],10)[0],'server readiness timeout'
    assert server.stdout.readline().strip()=='ready'
    client_code="""
import socket,urllib.request
v=urllib.request.build_opener(urllib.request.ProxyHandler({})).open('http://198.51.100.2:18080',timeout=10).read();assert v==b'198.51.100.1',v
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.settimeout(10);u.bind(('192.0.2.2',68));u.sendto(b'checksum-test',('198.51.100.2',1068));v,_=u.recvfrom(100);assert v==b'198.51.100.1',v
"""
    inside(NS[0],sys.executable,'-c',client_code)
    assert server.wait(timeout=10)==0,server.stderr.read()
    for table,target in [('nat','MASQUERADE'),('mangle','CHECKSUM')]:
        listing=inside(NS[1],'iptables-legacy','-t',table,'-L','POSTROUTING','-v','-n')
        row=next(line for line in listing.splitlines() if target in line)
        assert int(row.split()[0])>0,(target,row)
    print('PASS isolated bridge/veth routing; real TCP+UDP SNAT/return traffic; live MASQUERADE and DHCP CHECKSUM packet counters')
finally:
    if server and server.poll() is None:server.kill();server.wait()
    for name in reversed(created):
        try:ip('netns','del',name)
        except Exception:pass
    run('umount','/run/netns')
