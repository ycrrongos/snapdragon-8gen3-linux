#!/usr/bin/env python3
"""Run as root inside a private mount/IPC/PID/net/cgroup namespace, not the host."""
import argparse
import ctypes
import fcntl
import mmap
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

def run(*args):
    subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--overlay',action='store_true')
a=parser.parse_args()
assert os.geteuid()==0
assert os.getpid()==1,'Use unshare --pid --fork --mount-proc, never run on the host'
assert Path('/proc/self/ns/net').readlink()!=Path('/proc/1/ns/net').readlink() or os.getpid()==1
base=Path(tempfile.mkdtemp(prefix='cerro-waydroid-core-'));mounted=[]
try:
    binder=base/'binder';binder.mkdir()
    run('mount','-t','binder','binder',str(binder));mounted.append(binder)
    with (binder/'binder-control').open('rb') as control:
        for name in ('binder','hwbinder','vndbinder'):
            device=bytearray(struct.pack('256sII',('wdtest-'+name).encode(),0,0))
            fcntl.ioctl(control.fileno(),0xc1086201,device,True)
            _,major,minor=struct.unpack('256sII',device)
            assert major>0
            fd=os.open(binder/('wdtest-'+name),os.O_RDWR|os.O_CLOEXEC)
            try:
                version=bytearray(4);fcntl.ioctl(fd,0xc0046209,version,True)
                assert struct.unpack('i',version)[0]==8
                # Real context-manager registration on each isolated device.
                fcntl.ioctl(fd,0x40046207,struct.pack('i',0))
            finally:os.close(fd)
    print('PASS binderfs: three separate devices, protocol8 and context-manager ioctls',flush=True)
    fd=os.memfd_create('waydroid-kernel-test',os.MFD_ALLOW_SEALING)
    try:
        os.ftruncate(fd,4096)
        mem=mmap.mmap(fd,4096)
        mem[:4]=b'ping'
        child=os.fork()
        if child==0:
            if mem[:4]!=b'ping':os._exit(2)
            mem[16:20]=b'pong';os._exit(0)
        _,status=os.waitpid(child,0)
        assert status==0 and mem[16:20]==b'pong'
        mem.close()
        fcntl.fcntl(fd,fcntl.F_ADD_SEALS,fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL)
        assert fcntl.fcntl(fd,fcntl.F_GET_SEALS)&fcntl.F_SEAL_WRITE
    finally:os.close(fd)
    print('PASS memfd: real parent/child shared mapping and seals',flush=True)
    for name in ('cpu','memory','io'):
        assert 'some ' in (Path('/proc/pressure')/name).read_text()
    for name in ('mnt','ipc','pid','net','uts','cgroup','user'):
        assert (Path('/proc/self/ns')/name).exists()
    assert {'cpu','memory','pids'}<=set(Path('/sys/fs/cgroup/cgroup.controllers').read_text().split())
    print('PASS PSI, cgroupv2 controllers and isolated PID/IPC/mount/net/UTS/cgroup namespaces',flush=True)
    if a.overlay:
        for name in ('lower','upper','work','merged'):(base/name).mkdir()
        (base/'lower/original').write_text('lower')
        opts=','.join(f'{k}={base/v}' for k,v in [('lowerdir','lower'),('upperdir','upper'),('workdir','work')])
        run('mount','-t','overlay','overlay','-o',opts,str(base/'merged'));mounted.append(base/'merged')
        assert (base/'merged/original').read_text()=='lower'
        (base/'merged/original').write_text('copy-up')
        assert (base/'lower/original').read_text()=='lower' and (base/'upper/original').read_text()=='copy-up'
        print('PASS overlay: real copy-up leaves lower layer intact',flush=True)
finally:
    for target in reversed(mounted):run('umount',str(target))
    shutil.rmtree(base)
