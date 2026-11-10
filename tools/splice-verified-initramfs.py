#!/usr/bin/env python3
"""Clone a new boot image and splice the exact daily initramfs from a verified boot.

Never modifies either input or the kernel tree's rescue initramfs. Outside the
bounded destination gzip member, every byte of the new boot image is retained.
"""
import argparse
import hashlib
from pathlib import Path
import re
import struct
import zlib

def require(ok,message):
    if not ok:raise ValueError(message)

def kernel_range(boot):
    require(boot[:8]==b'ANDROID!','Missing Android boot magic')
    size=struct.unpack_from('<I',boot,8)[0]
    page=struct.unpack_from('<I',boot,36)[0]
    version=struct.unpack_from('<I',boot,40)[0]
    require(version==2 and page==4096,'Only audited header-v2/page4096 is supported')
    require(struct.unpack_from('<I',boot,16)[0]==127,'Stub ramdisk must remain127bytes')
    require(page+size<=len(boot),'Short kernel payload')
    return page,page+size

def member(kernel):
    found=[];offset=0
    while True:
        offset=kernel.find(b'\x1f\x8b\x08',offset)
        if offset<0:break
        try:
            decoder=zlib.decompressobj(16+zlib.MAX_WBITS)
            raw=decoder.decompress(kernel[offset:],128*1024*1024)
            if decoder.eof and raw.startswith(b'070701'):
                count=len(kernel)-offset-len(decoder.unused_data)
                found.append((offset,count,raw))
        except zlib.error:pass
        offset+=3
    require(len(found)==1,'Expected exactly one embedded newc gzip archive')
    return found[0]

def entries(raw):
    at=0;result={}
    while raw[at:at+6]==b'070701':
        header=raw[at:at+110];size=int(header[54:62],16);nlen=int(header[94:102],16)
        name=raw[at+110:at+110+nlen-1].decode();start=(at+110+nlen+3)&~3
        require(start+size<=len(raw),'Truncated cpio entry')
        if name=='TRAILER!!!':return result
        result[name.removeprefix('./')]=raw[start:start+size]
        at=(start+size+3)&~3
    raise ValueError('Missing cpio trailer')

def splice(new_path,reference_path,reference_sha,out):
    require(out.resolve() not in (new_path.resolve(),reference_path.resolve()),'Output must differ from inputs')
    new=new_path.read_bytes();ref=reference_path.read_bytes()
    require(hashlib.sha256(ref).hexdigest()==reference_sha,'Reference SHA mismatch')
    ns,ne=kernel_range(new);rs,re_=kernel_range(ref)
    no,nsize,_=member(new[ns:ne]);ro,rsize,raw=member(ref[rs:re_])
    files=entries(raw);init=files.get('init',b'')
    require(re.search(rb'^CONSOLE_ON=0\s*$',init,re.M) is not None,'Reference is not daily')
    require(b'cerro_acm_log' in init and b'setup_acm' in init and b'cerro_fix_lib' in init,'Missing verified init safeguards')
    require('cerro-early-drm/start.sh' in files and b'cerro-early-drm/start.sh' in init,'Missing actual early DRM dependency path')
    for name in ('aux-hpd-bridge','pmic_glink','wcd939x-usbss','pmic_glink_altmode'):
        require('cerro-early-drm/'+name+'.ko' in files,'Missing early module '+name)
    require(rsize<=nsize,'Verified initramfs does not fit; do not relocate it')
    a=ns+no;b=a+nsize
    replacement=ref[rs+ro:rs+ro+rsize]+bytes(nsize-rsize)
    result=new[:a]+replacement+new[b:]
    require(len(result)==len(new) and result[:a]==new[:a] and result[b:]==new[b:],'Non-initramfs bytes changed')
    check=member(result[ns:ne]);require(check[2]==raw,'Spliced cpio differs from reference')
    require(len(result)==100663296,'Expected96MiB phone partition image')
    out.write_bytes(result)
    print('Preserved new kernel/header/DTB/stub outside gzip slot; exact verified daily+earlyDRM cpio')
    print(f'cpio_slot={nsize} copied={rsize} offset={a}')
    print(hashlib.sha256(result).hexdigest(),str(out))
    print('Header ID is retained by cloning; content SHA above is the deployment identity.')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('new_boot',type=Path);p.add_argument('reference',type=Path)
    p.add_argument('reference_sha');p.add_argument('output',type=Path)
    a=p.parse_args();splice(a.new_boot,a.reference,a.reference_sha,a.output)
