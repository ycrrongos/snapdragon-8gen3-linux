#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Import a host swap manifest after live identity/cache validation; no flash."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

def require(condition, message):
    if not condition:
        raise ValueError(message)

manifest, directory, slot, other, serial, root_uuid, parts, boot_size, dtbo_size = sys.argv[1:]
require(os.geteuid() == 0, '需要root')
data = json.loads(Path(manifest).read_text())
state = Path(directory) / 'state'
require(not state.exists() and not state.is_symlink(), '已有机内清单')
require(data['serial'] == serial and data['slot'] == slot and data['cache_slot'] == other, '设备或槽位不符')
require(data['root_uuid'].replace('-', '').lower() == root_uuid, 'Linux根分区不符')
require(int(data['dtbo_size']) == int(dtbo_size), '分区尺寸不符')
require(data.get('phase') in ('linux_booted', 'linux_ready', 'android_booted', 'android_ready'), '电脑操作尚未完成')
for field in ('android_boot', 'android_dtbo', 'linux_boot'):
    require(re.fullmatch('[0-9a-f]{64}', data[field]), '清单SHA格式错误')

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

parts = Path(parts)
for kind in ('boot', 'dtbo'):
    require(digest(parts / f'{kind}_{other}') == data['android_' + kind], 'Android缓存不符')
# A later legitimate Linux kernel update can differ from the host's older image.
# Preserve the observed hash; restore still requires both exact cached Android hashes.
with (parts / f'boot_{slot}').open('rb') as stream:
    header = stream.read(4096)
require(header[:8] == b'ANDROID!' and b'cerro_boot=' in header, '活动boot不是Cerro Linux')
linux_sha = digest(parts / f'boot_{slot}')
values = dict(version='1', serial=serial, slot=slot, cache_slot=other,
              root_uuid=root_uuid, boot_size=str(int(boot_size)), dtbo_size=str(int(dtbo_size)),
              android_boot=data['android_boot'], android_dtbo=data['android_dtbo'],
              linux_boot=linux_sha, run=f'host-import-slot_{slot}-{time.time_ns()}', phase='linux_ready')
for value in values.values():
    require(re.fullmatch('[A-Za-z0-9_.-]+', value), '清单内容格式不符')
fd, name = tempfile.mkstemp(prefix='.state-import-', dir=directory)
try:
    with os.fdopen(fd, 'w') as stream:
        stream.write(''.join(f'{key}={value}\n' for key, value in values.items()))
        stream.flush()
        os.fsync(stream.fileno())
    os.rename(name, state)
    dirfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(dirfd)
    finally: os.close(dirfd)
finally:
    if os.path.exists(name): os.unlink(name)
print('电脑清单已导入；缓存双文件/槽位/根分区均核对，未改写任何分区。')
