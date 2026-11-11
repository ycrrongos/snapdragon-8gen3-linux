#!/usr/bin/env python3
"""Safety gates: denied contexts must never reach the metadata write."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('desktop_success', Path(__file__).with_name('desktop-boot-success.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class DesktopSuccessTests(unittest.TestCase):
    def test_slot_mismatch_refuses(self):
        with patch.object(m, 'run', side_effect=['Current slot: _b', 'Active slot: _a']) as run:
            with self.assertRaises(RuntimeError): m.slot_pair()
            self.assertEqual(run.call_count, 2)

    def test_malformed_slot_refuses(self):
        with patch.object(m, 'run', side_effect=['unknown', 'Active slot: _b']):
            with self.assertRaises(RuntimeError): m.slot_pair()

    def test_ssh_only_refuses_before_dbus(self):
        with patch.object(m, 'run', side_effect=['3 1000 rong -', 'User=1000\nActive=yes\nRemote=no\nType=tty']) as run:
            with self.assertRaises(RuntimeError): m.desktop_ready(1000)
            self.assertEqual(run.call_count, 2)

    def test_remote_graphical_refuses(self):
        with patch.object(m, 'run', side_effect=['3 1000 rong -', 'User=1000\nActive=yes\nRemote=yes\nType=wayland']):
            with self.assertRaises(RuntimeError): m.desktop_ready(1000)

    def test_missing_desktop_never_writes(self):
        with patch.object(m.Path, 'read_bytes', return_value=b'nubia,cerro\0'), \
             patch.object(m.Path, 'read_text', return_value='cerro_boot=test'), \
             patch.object(m, 'desktop_ready', side_effect=RuntimeError('No desktop')), \
             patch.object(m, 'run') as run:
            with self.assertRaises(RuntimeError): m.mark(1000)
            run.assert_not_called()

    def test_readback_failure_is_not_success(self):
        with patch.object(m.Path, 'read_bytes', return_value=b'nubia,cerro\0'), \
             patch.object(m.Path, 'read_text', return_value='cerro_boot=test'), \
             patch.object(m, 'desktop_ready'), patch.object(m, 'slot_pair', return_value='_b'), \
             patch.object(m, 'run', side_effect=['marked', 'SLOT _b: is not marked successful']) as run:
            with self.assertRaises(RuntimeError): m.mark(1000)
            self.assertEqual(run.call_args_list[0].args, ('/usr/bin/qbootctl', '-m'))
            self.assertEqual(run.call_count, 2)

    def test_verified_boot_and_bootable_required(self):
        with patch.object(m.Path, 'read_bytes', return_value=b'nubia,cerro\0'), \
             patch.object(m.Path, 'read_text', side_effect=['cerro_boot=test', 'test-boot-id']), \
             patch.object(m, 'desktop_ready'), patch.object(m, 'slot_pair', return_value='_b'), \
             patch.object(m, 'run', side_effect=['marked', 'SLOT _b: is marked successful', 'SLOT _b: is marked bootable']):
            self.assertEqual(m.mark(1000)['boot_id'], 'test-boot-id')


if __name__ == '__main__': unittest.main()
