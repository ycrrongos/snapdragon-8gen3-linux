#!/usr/bin/env python3
"""Stage the complete runtime dependency closure from a normally built kernel."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

WANTED=('veth','bridge','br_netfilter','overlay','nf_conntrack','nf_nat','ip_tables',
        'iptable_filter','iptable_nat','iptable_mangle','ip6_tables','ip6table_filter',
        'ip6table_nat','ip6table_mangle','xt_MASQUERADE','xt_CHECKSUM','xt_comment','xt_conntrack','xt_tcpudp')
def info(path,field):
    return subprocess.check_output(['modinfo','-F',field,str(path)],text=True).strip()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('kernel',type=Path);p.add_argument('destination',type=Path);a=p.parse_args()
assert not a.destination.exists(),'Use a new staging directory'
index={}
for f in a.kernel.rglob('*.ko'):
    index.setdefault(f.stem.replace('-','_'),[]).append(f)
closure={}
def add(name):
    name=name.replace('-','_')
    if name in closure:return
    candidates=index.get(name,[]);assert len(candidates)==1,(name,candidates)
    source=candidates[0];assert info(source,'vermagic').split()[0]=='7.2.0-rc5-dirty'
    closure[name]=source
    for dep in info(source,'depends').split(','):
        if dep:add(dep)
for name in WANTED:add(name)
a.destination.mkdir(parents=True)
manifest={}
for name,source in sorted(closure.items()):
    target=a.destination/source.name;shutil.copyfile(source,target)
    subprocess.run(['llvm-strip','--strip-debug',str(target)],check=True)
    manifest[target.name]={'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
                           'depends':info(source,'depends'),'vermagic':info(source,'vermagic')}
(a.destination/'modules.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Staged',len(manifest),'same-ABI modules including recursive dependencies')
