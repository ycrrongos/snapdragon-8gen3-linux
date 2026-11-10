#!/usr/bin/env python3
"""Export audited source only to a separate public git history; optionally push."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REPO = 'ycrrongos/snapdragon-8gen3-linux'
AUTHOR = 'ycrrongos'
EMAIL = '124893015+ycrrongos@users.noreply.github.com'
EXTENSIONS = {'.py','.sh','.c','.h','.cpp','.S','.patch','.dts','.dtsi','.fragment',
              '.config','.service','.conf','.rules','.policy','.desktop','.md','.txt',
              '.json','.toml','.xml','.java','.pro','.in','.yaml','.yml','.mk','.rc','.bp','.fstab','.flags'}
EXCLUDE_DIRS = {'out','bin','obj','gen','venv','.git','edl','nubia_sm8650_eng',
                'firmware','__pycache__','phone-bridge','dt','android-sensor-refs',
                'android-voice-refs'}
EXCLUDE_FILES = {'patches/camera-board-c1/load-runtime.sh', 'patches/camera-optics-c1/install-lens-runtime.sh', 'tools/edl-tools/flash-caza-fastbootd.sh', 'tools/cerro-dualboot/linux/cerro-dpms.cpp'}
ROOT_FILES = {'README.md','Makefile','COPYING','NOTICE','.gitignore','BUILD_GUIDE.md'}
SECRET = re.compile(rb'(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY)')
# Known device-local strings must not escape through copied documentation.
private_file = ROOT / '.publication-private.json'
PRIVATE_STRINGS = tuple(json.loads(private_file.read_text())['strings']) if private_file.exists() else ()

def run(*args, cwd=None, env=None, capture=False):
    return subprocess.run(args, cwd=cwd, env=env, check=True,
                          stdout=subprocess.PIPE if capture else None, text=True)

def export(destination):
    selected = {Path(n) for n in ROOT_FILES if (ROOT / n).is_file()}
    for directory in ('tools','patches','linux','kernel','docs','notes/alsa-ucm-sm8650-cerro','recovery/orangefox'):
        for p in (ROOT / directory).rglob('*'):
            rel = p.relative_to(ROOT)
            if not p.is_file() or p.is_symlink() or any(x in EXCLUDE_DIRS for x in rel.parts):
                continue
            if str(rel) in EXCLUDE_FILES: continue
            if p.name.startswith('.') or p.name.endswith(('.mod.c','.orig','.stock-bak')):
                continue
            if p.suffix in EXTENSIONS or p.name in {'Makefile','Kconfig','meson.build','HiFi','VoiceCall'}:
                selected.add(rel)
    contents = {}
    for rel in sorted(selected):
        p = ROOT / rel
        data = p.read_bytes()
        if len(data) > 700000 or b'\x00' in data or SECRET.search(data):
            raise SystemExit(f'Publication rejects binary/oversized/secret input: {rel}')
        text = data.decode('utf-8')
        if rel.suffix in {'.md','.txt'}:
            for private in PRIVATE_STRINGS:
                text = text.replace(private, '<device-local>')
            text = re.sub(r'192\.168\.0\.\d+', '<phone-wifi-ip>', text)
            text = re.sub(r'(?<![A-Za-z0-9])(?:112|940)(?![A-Za-z0-9])', '<per-unit-focus>', text)
        else:
            # Do not silently rewrite executable semantics. These must be fixed at source.
            if any(value in text for value in PRIVATE_STRINGS):
                raise SystemExit(f'Publication rejects device-specific source: {rel}')
        contents[str(rel)] = text.encode()
    contents['AGENTS.md'] = (ROOT / 'docs/PUBLIC_AGENTS.md').read_bytes()
    manifest = {name: hashlib.sha256(data).hexdigest() for name,data in sorted(contents.items())}
    contents['PUBLICATION.json'] = (json.dumps({'format':1,'files':manifest}, indent=2)+'\n').encode()
    destination.mkdir(parents=True, exist_ok=True)
    # Only this dedicated checkout is managed; never wipe the source project.
    old = set()
    if (destination / 'PUBLICATION.json').exists():
        old = set(json.loads((destination / 'PUBLICATION.json').read_text())['files'])
    for name in old - set(contents):
        p = destination / name
        if p.is_file(): p.unlink()
    for name,data in contents.items():
        p = destination / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        source = ROOT / name
        p.chmod(0o755 if source.exists() and os.access(source, os.X_OK) else 0o644)
    print(f'Exported {len(manifest)} text source/recipe/document files, {sum(map(len,contents.values()))} bytes')

def publish(destination, message, push, export_only=False):
    destination = destination.resolve()
    if destination == ROOT or ROOT.is_relative_to(destination):
        raise SystemExit('Use a separate publication checkout, never the source project')
    if not (destination / '.git').exists():
        destination.mkdir(parents=True,exist_ok=True)
        run('git','init','-b','main',str(destination))
        run('git','remote','add','origin','https://github.com/'+REPO+'.git',cwd=destination)
    actual = run('git','remote','get-url','origin',cwd=destination,capture=True).stdout.strip()
    if actual != 'https://github.com/'+REPO+'.git':
        raise SystemExit('Wrong publication remote')
    export(destination)
    if export_only: return
    run('python3',str(ROOT/'tools/publication/audit.py'),str(destination))
    run('make','test',cwd=destination)
    run('git','config','user.name',AUTHOR,cwd=destination)
    run('git','config','user.email',EMAIL,cwd=destination)
    run('git','add','-A',cwd=destination)
    changed = subprocess.run(['git','diff','--cached','--quiet'],cwd=destination).returncode
    if changed:
        run('git','-c','core.hooksPath=/dev/null','commit','-m',message,cwd=destination)
    if push:
        # Token is read only by the transient credential helper, never in args or stdout.
        token_file = Path(os.environ.get('CERRO_GITHUB_TOKEN_FILE', ROOT/'GITHUBTOKEN.txt')).resolve()
        with tempfile.TemporaryDirectory(prefix='cerro-push-') as d:
            helper = Path(d)/'askpass.py'
            helper.write_text("#!/usr/bin/env python3\nimport os,re,pathlib,sys\n"
                "if 'Username' in sys.argv[1]: print('x-access-token')\n"
                "else:\n s=pathlib.Path(os.environ['CERRO_GITHUB_TOKEN_FILE']).read_text()\n"
                " m=re.search(r'(?:github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9]+)',s)\n"
                " if not m: raise SystemExit('token unavailable')\n print(m.group())\n")
            helper.chmod(0o700)
            env=os.environ.copy();env.update(GIT_ASKPASS=str(helper),GIT_TERMINAL_PROMPT='0',CERRO_GITHUB_TOKEN_FILE=str(token_file))
            run('git','-c','credential.helper=','push','-u','origin','main',cwd=destination,env=env)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dest',type=Path,default=ROOT/'build/public-repo')
    parser.add_argument('--message',default='Update verified SM8650 Linux port sources')
    parser.add_argument('--push',action='store_true')
    parser.add_argument('--export-only',action='store_true',help='audit/export without committing or pushing')
    args=parser.parse_args()
    publish(args.dest,args.message,args.push,args.export_only)
