#!/usr/bin/env python3
"""Read-only real Android readiness and service stability checks on the phone."""
import argparse
import json
import os
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--observe-seconds', type=int, default=120)
a = p.parse_args()
assert os.geteuid() == 0, 'Run as root on the phone'
assert 0 <= a.observe_seconds <= 600
base = ['lxc-attach', '-P', '/var/lib/waydroid/lxc', '-n', 'waydroid', '--']

def android(*args):
    return subprocess.check_output(base + list(args), text=True, timeout=30).strip()

assert android('getprop', 'sys.boot_completed') == '1', 'Android boot not completed'
assert android('getprop', 'init.svc.netd') == 'running', 'netd not running'
assert android('getprop', 'init.svc.surfaceflinger') == 'running'
assert 'inet ' in android('ip', '-4', 'address', 'show', 'eth0'), 'No IPv4 lease'
# Attach creates a process that cannot run while the legitimate idle freezer
# is active. Observe existing processes through the host /proc namespace instead.
init_pid = subprocess.check_output(['lxc-info', '-P', '/var/lib/waydroid/lxc',
                                   '-n', 'waydroid', '-pH'], text=True).strip()
namespace = os.readlink('/proc/' + init_pid + '/ns/pid')
names = ('netd', 'system_server', 'surfaceflinger')
def snapshot():
    result = {}
    from pathlib import Path
    for path in Path('/proc').glob('[0-9]*'):
        try:
            if os.readlink(path / 'ns/pid') != namespace:
                continue
            # netd's leader changes comm to a binder thread name; argv0 stays stable.
            name = os.path.basename((path / 'cmdline').read_bytes().split(b'\0')[0].decode())
            if name not in names:
                continue
            fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            assert fields[0] != 'Z', name + ' is a zombie'
            assert name not in result, name + ' has multiple process leaders'
            result[name] = (int(path.name), fields[19])
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    assert set(result) == set(names), result
    return result
pids = snapshot()
print(json.dumps({'boot_completed': True, 'initial_host_pids': pids}), flush=True)
end = time.monotonic() + a.observe_seconds
while time.monotonic() < end:
    time.sleep(max(0, min(10, end - time.monotonic())))
    assert snapshot() == pids, 'Android core process restarted'
print('PASS Android boot completed, DHCP address, netd/system_server/SurfaceFlinger stable for', a.observe_seconds, 'seconds, including legitimate idle freeze')
print('Real GUI rendering, app input, DNS/HTTPS and GPU verification are separate acceptance steps.')
