#!/usr/bin/python3
"""Prepare the real Cerro camera suppliers and graph before CAMSS probes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

UNIT = Path('/var/lib/cerro-camera')
DT = Path('/sys/firmware/devicetree/base')
GRAPH = DT / 'soc@0/rsc@17a00000/camera-pm8010m-regulators'
CCI1 = Path('/sys/bus/platform/devices/ac16000.cci')
CAMCC = Path('/sys/bus/platform/devices/ade0000.clock-controller/driver')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def command(args):
    return subprocess.run(args, check=True, timeout=12, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def module(name, *options):
    print('camera-start: load ' + name, flush=True)
    command(['/sbin/modprobe', name, *options])


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise RuntimeError('Hardware dependency missing: ' + description)


def calibration():
    meta = json.loads((UNIT / 'unit.json').read_text())
    raw = (UNIT / 'imx800-eeprom-first64.bin').read_bytes()
    require(len(raw) == 64 and hashlib.sha256(raw).hexdigest() == meta['sha256'],
            'Private unit calibration integrity failure')
    macro, infinity = int.from_bytes(raw[13:15], 'big'), int.from_bytes(raw[15:17], 'big')
    require(0 < infinity < macro <= 1023, 'Invalid factory focus bounds')
    return infinity, macro


def graph_ready():
    bound = {}
    for device in Path('/sys/bus/i2c/devices').glob('*-*'):
        driver = device / 'driver'
        if driver.exists():
            bound[driver.resolve().name] = True
    if not all(bound.get(name) for name in ('imx800-cerro', 'ak7316-cerro', 'ov12d2q-cerro')):
        return False
    if not Path('/sys/bus/platform/devices/acb6000.isp/driver').exists():
        return False
    for media in Path('/dev').glob('media*'):
        topology = command(['/usr/bin/media-ctl', '-d', str(media), '-p'])
        if all(name in topology for name in ('imx800-cerro', 'ak7316-cerro', 'ov12d2q-cerro')):
            return True
    return False


def start():
    require((DT / 'compatible').read_bytes().split(b'\0')[0] == b'nubia,cerro', 'Wrong device')
    infinity, macro = calibration()
    require(not GRAPH.exists(), 'Graph already present; never remove/reapply a live overlay')
    require(not Path('/sys/module/qcom_camss').exists(),
            'CAMSS loaded before graph; refusing to hide ordering with a rebind')
    module('camcc-sm8650')
    wait_for(lambda: CAMCC.exists() and CAMCC.resolve().name == 'camcc-sm8650', 'CAMCC supplier bound')

    # CCI1's unused master1 formerly held the main camera GPIO13. Preserve
    # master0 for the ultrawide; do not unbind a bus containing live clients.
    for adapter in Path('/sys/bus/i2c/devices').glob('i2c-*'):
        if '/cci@ac16000/i2c-bus@' in (adapter / 'of_node').resolve().as_posix():
            number = adapter.name.removeprefix('i2c-')
            require(not list(Path('/sys/bus/i2c/devices').glob(number + '-*')),
                    'CCI1 has a live client; refusing to unbind')
    if (CCI1 / 'driver').exists():
        Path('/sys/bus/platform/drivers/i2c-qcom-cci/unbind').write_text('ac16000.cci')
    module('ak7316-cerro')
    module('imx800-cerro')
    module('ov12d2q-cerro')
    module('cerro-camera-board', 'focus_min=' + str(infinity), 'focus_max=' + str(macro))
    require(GRAPH.exists(), 'Board graph was not installed')
    module('cerro-front-board')
    print('camera-start: main/front graphs installed before CAMSS', flush=True)
    module('i2c-qcom-cci')
    if not (CCI1 / 'driver').exists():
        Path('/sys/bus/platform/drivers/i2c-qcom-cci/bind').write_text('ac16000.cci')
    module('system_heap')
    module('cma_heap')
    module('qcom-camss')
    wait_for(graph_ready, 'bound sensor/lens and CAMSS media graph')
    print('camera-start: sensor/lens/media graph ready on first probe', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-calibration', action='store_true')
    args = parser.parse_args()
    if args.check_calibration:
        calibration()
        print('Private unit calibration valid')
    else:
        start()
