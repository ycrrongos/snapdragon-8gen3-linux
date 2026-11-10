#!/usr/bin/env python3
"""Prepare a pinned, patch-verified kernel in a new directory; never touch a live tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)

def prepare(destination, source=None):
    lock = json.loads((ROOT / 'kernel/source.lock.json').read_text())
    for name, key in [('cerro.patch', 'patch_sha256'), ('cerro.config', 'config_sha256')]:
        if hashlib.sha256((ROOT / 'kernel' / name).read_bytes()).hexdigest() != lock[key]:
            raise SystemExit(f'{name}: does not match source.lock.json')
    destination = destination.resolve()
    if destination.exists():
        raise SystemExit(f'Refusing existing directory: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.cerro-prepare-', dir=destination.parent))
    tree = temporary / 'tree'
    try:
        if source:
            # An offline local mirror is optional; export the *upstream* commit,
            # never its working tree or local patch state.
            run('git', 'clone', '--no-checkout', '--shared', str(source.resolve()), str(tree))
            run('git', 'checkout', '--detach', lock['upstream_commit'], cwd=tree)
        else:
            run('git', 'clone', '--depth=1', '--branch', lock['upstream_ref'], lock['upstream_url'], str(tree))
        observed = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=tree, text=True).strip()
        if observed != lock['upstream_commit']:
            raise SystemExit('Upstream tag moved: refusing unpinned source')
        patch = str(ROOT / 'kernel/cerro.patch')
        run('git', 'apply', '--check', patch, cwd=tree)
        run('git', 'apply', patch, cwd=tree)
        shutil.copyfile(ROOT / 'kernel/cerro.config', tree / '.config')
        # Preserve local assembly independently of any user's global git identity.
        run('git', 'add', '-A', cwd=tree)
        run('git', '-c', 'user.name=Cerro source assembly', '-c', 'user.email=assembly@localhost',
            'commit', '-m', 'Apply pinned Cerro port sources (see kernel/source.lock.json)', cwd=tree)
        (tree / '.cerro-source.json').write_text(json.dumps(lock, indent=2) + '\n')
        os.rename(tree, destination)
        print(f'Prepared {destination}; no phone accessed')
    finally:
        shutil.rmtree(temporary)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dest', type=Path, default=ROOT / 'build/linux-7.2')
    parser.add_argument('--source', type=Path, help='optional offline git mirror containing the pinned upstream commit')
    args = parser.parse_args()
    prepare(args.dest, args.source)
