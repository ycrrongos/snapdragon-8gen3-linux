#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
"""Cerro firmware SDP current policy, driven by real power-supply events."""
import fcntl
import os
from pathlib import Path
import sys


def target_current(values, temperature):
    # Board-specific: stock Android requests 900mA on this firmware/PC source.
    # Never apply this quirk to PD/DCP, an offline supply or unknown capacity.
    if values.get('POWER_SUPPLY_ONLINE') != '1' or '[SDP]' not in values.get('POWER_SUPPLY_USB_TYPE', ''):
        return None
    try:
        voltage = int(values['POWER_SUPPLY_VOLTAGE_NOW'])
        maximum = int(values['POWER_SUPPLY_CURRENT_MAX'])
        current = int(values['POWER_SUPPLY_INPUT_CURRENT_LIMIT'])
    except (KeyError, ValueError):
        return None
    if not 4500000 <= voltage <= 5500000 or not 0 <= temperature < 400:
        return None
    # Only the locally verified 900mA firmware class, not every USB host.
    if maximum != 900000 or current >= maximum:
        return None
    return maximum


def main():
    compatible = Path('/sys/firmware/devicetree/base/compatible').read_bytes().split(b'\0')
    if b'nubia,cerro' not in compatible:
        return
    fd = os.open('/run/lock/cerro-usb-current.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        supply = Path('/sys/class/power_supply/qcom-battmgr-usb')
        values = dict(line.split('=', 1) for line in (supply / 'uevent').read_text().splitlines() if '=' in line)
        temperature = int(Path('/sys/class/power_supply/qcom-battmgr-bat/temp').read_text())
        requested = target_current(values, temperature)
        if requested is None:
            return
        (supply / 'input_current_limit').write_text(str(requested) + '\n')
        print('Cerro SDP input request: ' + str(requested) + 'uA (firmware maximum); readback=' + (supply / 'input_current_limit').read_text().strip())
    finally:
        os.close(fd)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError) as error:
        print('cerro-usb-current: ' + str(error), file=sys.stderr)
        sys.exit(1)
