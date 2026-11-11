#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Confirm this boot only after an active local Plasma desktop is available."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=10, check=True)
    return result.stdout.strip()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def properties(text):
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def desktop_ready(uid):
    name = pwd.getpwuid(uid).pw_name
    sessions = run('/usr/bin/loginctl', 'list-sessions', '--no-legend', '--no-pager')
    found = False
    for line in sessions.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[1] != str(uid):
            continue
        props = properties(run('/usr/bin/loginctl', 'show-session', fields[0],
                               '-p', 'User', '-p', 'Active', '-p', 'Remote', '-p', 'Type'))
        if (props.get('User') == str(uid) and props.get('Active') == 'yes'
                and props.get('Remote') == 'no' and props.get('Type') in ('wayland', 'x11')):
            found = True
            break
    require(found, 'No active local graphical login for caller; not marking boot')
    for busname, executable in (('org.kde.plasmashell', 'plasmashell'), ('org.kde.KWin', 'kwin_wayland')):
        reply = run('/usr/sbin/runuser', '-u', name, '--', '/usr/bin/env',
                    f'XDG_RUNTIME_DIR=/run/user/{uid}',
                    f'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus',
                    '/usr/bin/busctl', '--user', 'call', 'org.freedesktop.DBus',
                    '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                    'GetConnectionUnixProcessID', 's', busname)
        match = re.fullmatch(r'u ([0-9]+)', reply)
        require(match is not None, 'Desktop DBus owner is unavailable')
        proc = Path('/proc') / match[1]
        require(proc.stat().st_uid == uid, 'Desktop process owner mismatch')
        actual = (proc / 'exe').resolve().name
        require(actual == executable or (busname == 'org.kde.KWin' and actual == 'kwin_x11'),
                'Unexpected desktop executable')


def slot_pair():
    current = run('/usr/bin/qbootctl', '-c')
    active = run('/usr/bin/qbootctl', '-a')
    c = re.fullmatch(r'Current slot: (_[ab])', current)
    a = re.fullmatch(r'Active slot: (_[ab])', active)
    require(c is not None and a is not None and c[1] == a[1],
            'Current/active slot missing or disagree; not marking boot')
    return c[1]


def mark(uid):
    compatible = Path('/sys/firmware/devicetree/base/compatible').read_bytes().split(b'\0')
    require(b'nubia,cerro' in compatible, 'This helper only supports Cerro')
    require('cerro_boot=' in Path('/proc/cmdline').read_text(), 'Missing Cerro Linux boot marker')
    desktop_ready(uid)
    slot = slot_pair()
    # Native qbootctl updates Qualcomm GPT flags; never set_active or write images.
    result = run('/usr/bin/qbootctl', '-m')
    require(slot_pair() == slot, 'Slot changed while marking boot')
    index = '0' if slot == '_a' else '1'
    require(run('/usr/bin/qbootctl', '-n', index) == f'SLOT {slot}: is marked successful',
            'Boot-success readback failed')
    require(run('/usr/bin/qbootctl', '-b', index) == f'SLOT {slot}: is marked bootable',
            'Bootable readback failed')
    return dict(boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                slot=slot, uid=uid, successful=True, detail=result)


def main():
    require(os.geteuid() == 0, 'Run through installed polkit action')
    uid_text = os.environ.get('PKEXEC_UID', '')
    require(uid_text.isdecimal() and int(uid_text) >= 1000, 'Missing desktop caller identity')
    require(len(sys.argv) == 1, 'No arguments accepted')
    lock = os.open('/run/lock/cerro-desktop-boot-success.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = mark(int(uid_text))
        target = Path('/run/cerro-desktop-boot-success.json')
        temporary = target.with_suffix('.new')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(result, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        print('Desktop ready; active slot ' + result['slot'] + ' marked successful and verified')
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('cerro-desktop-boot-success: ' + str(error), file=sys.stderr)
        sys.exit(1)
