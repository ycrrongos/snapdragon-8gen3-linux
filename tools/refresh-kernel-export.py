#!/usr/bin/env python3
"""Refresh the public complete in-tree delta/config from a clean local kernel git.
This does not build, test, publish or change the kernel tree.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--kernel',type=Path,default=ROOT/'build/linux-7.2');a=p.parse_args()
def git(*args):return subprocess.check_output(['git','-C',str(a.kernel),*args],text=True).strip()
assert not git('status','--porcelain'),'Commit kernel source changes first; never reset/clean'
lock=json.loads((ROOT/'kernel/source.lock.json').read_text());base=lock['upstream_commit'];head=git('rev-parse','HEAD')
paths=git('diff','--name-only',base,head).splitlines()
paths=[x for x in paths if x!='.config' and not x.startswith(('out/','usr/')) and not x.endswith(('.orig','.stock-bak'))]
patch=subprocess.check_output(['git','-C',str(a.kernel),'diff','--binary',base,head,'--',*paths])
config=(a.kernel/'.config').read_text()
config='\n'.join('CONFIG_INITRAMFS_SOURCE=""' if x.startswith('CONFIG_INITRAMFS_SOURCE=') else x for x in config.splitlines())+'\n'
(ROOT/'kernel/cerro.patch').write_bytes(patch);(ROOT/'kernel/cerro.config').write_text(config)
lock.update(tested_source_commit=head,patch_sha256=hashlib.sha256(patch).hexdigest(),config_sha256=hashlib.sha256(config.encode()).hexdigest())
(ROOT/'kernel/source.lock.json').write_text(json.dumps(lock,indent=2)+'\n')
print('Refreshed',len(paths),'in-tree paths and source-only config; validation still required')
