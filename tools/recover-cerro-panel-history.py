#!/usr/bin/env python3
"""Recover the RM692H0 on() source from archived Cursor JSONL, without running it.

Usage: recover-cerro-panel-history.py BACKUP.zip OUTPUT.c
Only reads transcript strings; never executes historical shell/tool commands.
The output is the final on() function, including packet types and rate selection.
"""
import argparse
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
with zipfile.ZipFile(args.archive) as archive:
    names = [n for n in archive.namelist()
             if n.endswith('/7f8c3d7b-e1c5-491d-8eb9-de823eab4190.jsonl')]
    if len(names) != 1:
        raise SystemExit('Expected exactly one main display transcript')
    events = [json.loads(line) for line in archive.read(names[0]).decode().splitlines()]
source = None
prefix = None
replacements = []
for event in events:
    for block in event.get('message', {}).get('content', []):
        if block.get('type') != 'tool_use':
            continue
        change = block.get('input', {})
        if not change.get('path', '').endswith('/panel-raydium-rm692h0.c'):
            continue
        old, new = change.get('old_string'), change.get('new_string')
        if old is None or new is None:
            continue
        if source is None:
            if new.startswith('static void rm692h0_on(') and 's5bc:' in new:
                source = new
            continue
        if old in source:
            source = source.replace(old, new)
        if new.startswith('static void rm692h0_on(') and 'unsigned int hz)' in new:
            prefix = new
        replacements.append((old, new))
if source is None or prefix is None:
    raise SystemExit('Missing s5bc seed or final s5ew prefix')
marker = '\t/* SKIP: 0x15, 0xb3, 0x7f'
end_comment = source.index('\n', source.index(marker))
source = prefix + source[end_comment:]
for old, new in replacements:
    if old in source:
        source = source.replace(old, new)
if source.count('rm692h0_dcs_typed_write_seq_multi(') != 242:
    raise SystemExit('Unexpected packet count; review transcript before using output')
if 'u8 bd_cmd[] = { 0xbd, bd };' not in source:
    raise SystemExit('Missing final dynamic BD fix')
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(source + '\n')
print(f'Recovered {args.output}: 242 constant messages + 1 dynamic BD message')
