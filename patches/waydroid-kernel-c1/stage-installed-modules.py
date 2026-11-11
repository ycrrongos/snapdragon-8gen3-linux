#!/usr/bin/env python3
"""Stage every installed module from one matched kernel/config, or fail closed.

Inventory: one relative usr/lib/modules/RELEASE/...ko path per line. Absolute
Android mount paths ending in the same usr/lib/modules suffix are accepted too.
Repeat --external for freshly rebuilt external-module directories. No install.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('kernel',type=Path)
p.add_argument('inventory',type=Path)
p.add_argument('destination',type=Path)
p.add_argument('--external',type=Path,action='append',default=[])
p.add_argument('--release',default='7.2.0-rc5-dirty')
a=p.parse_args()
assert not a.destination.exists(), 'Choose a new staging directory'
assert not subprocess.check_output(['git','-C',str(a.kernel),'status','--porcelain']), 'Commit kernel changes first'
index=defaultdict(list)
for root in (a.kernel,*a.external):
    for source in root.rglob('*.ko'):
        index[source.name].append(source)
plan={}
for line in a.inventory.read_text().splitlines():
    anchor='usr/lib/modules/' + a.release + '/'
    assert line.count(anchor)==1,line
    relative=anchor + line.split(anchor,1)[1]
    path=Path(relative)
    assert '..' not in path.parts and path.suffix=='.ko',relative
    assert len(index[path.name])==1,(relative,index[path.name])
    source=index[path.name][0]
    release=subprocess.check_output(['modinfo','-F','vermagic',str(source)],text=True).split()[0]
    assert release==a.release,(relative,release)
    plan[relative]=source
assert plan,'Empty inventory'
a.destination.mkdir()
files={};done={}
for relative,source in sorted(plan.items()):
    name=source.name
    if name not in done:
        target=a.destination/name
        shutil.copyfile(source,target)
        subprocess.run(['llvm-strip','--strip-debug',str(target)],check=True)
        done[name]=hashlib.sha256(target.read_bytes()).hexdigest()
    files[relative]={'file':name,'sha256':done[name]}
(a.destination/'manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print('Staged',len(files),'installed paths /',len(done),'distinct modules from one config, including explicit external builds')
