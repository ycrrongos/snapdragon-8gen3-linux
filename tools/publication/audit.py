#!/usr/bin/env python3
"""Validate a source export manifest and executable syntax before publishing."""
import argparse
import hashlib
import json
from pathlib import Path
import py_compile
import re
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory',type=Path)
args=parser.parse_args();root=args.directory.resolve()
manifest=json.loads((root/'PUBLICATION.json').read_text())['files']
required={'AGENTS.md','README.md','NOTICE','COPYING','kernel/source.lock.json',
          'kernel/cerro.patch','kernel/cerro.config','tools/prepare-kernel.py',
          'tools/build-source.sh','patches/camera-imx800-c1/imx800-cerro.c',
          'patches/camera-startup-c1/start-camera.py'}
assert required<=set(manifest),required-set(manifest)
for name,expected in manifest.items():
    p=root/name
    assert p.is_relative_to(root) and p.is_file() and not p.is_symlink(),name
    assert not any(x in {'backups','logs','out','__pycache__'} for x in p.relative_to(root).parts),name
    b=p.read_bytes()
    assert b'\0' not in b and len(b)<700000,name
    assert hashlib.sha256(b).hexdigest()==expected,name
    assert not re.search(rb'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY',b),name
    if p.suffix=='.py':
        with tempfile.TemporaryDirectory() as d:
            py_compile.compile(str(p),cfile=str(Path(d)/'bytecode'),doraise=True)
    if p.suffix=='.sh':
        subprocess.run(['bash','-n',str(p)],check=True)
lock=json.loads((root/'kernel/source.lock.json').read_text())
for name,key in [('cerro.patch','patch_sha256'),('cerro.config','config_sha256')]:
    assert hashlib.sha256((root/'kernel'/name).read_bytes()).hexdigest()==lock[key]
print(f'Audited {len(manifest)} manifest files: hashes, text/size/secrets, Python/shell syntax and source lock')
