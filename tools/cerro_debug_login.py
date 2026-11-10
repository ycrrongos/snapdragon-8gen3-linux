#!/usr/bin/env python3
"""Load ignored, owner-only Cerro credentials; never embed passwords in source."""
import getpass
import json
import os
from pathlib import Path
import stat


def defaults():
    path = Path(os.environ.get('CERRO_CREDENTIALS_FILE', Path(__file__).resolve().parents[1] / 'build/private/cerro-debug-credentials.json'))
    data = {}
    if path.exists():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Cerro credential file must be an owner-only regular file (0600)')
        data = json.loads(path.read_text())
    return (os.environ.get('CERRO_USER', data.get('username', 'rong')),
            os.environ.get('CERRO_PASSWORD', data.get('password')))


def password_or_prompt(password):
    if password is not None:
        return password
    return getpass.getpass('Cerro password: ')
