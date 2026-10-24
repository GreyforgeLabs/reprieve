#!/usr/bin/env python3
"""Health checks must catch an enabled but missing flight renderer."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'bin/reprieve-doctor'
loader = importlib.machinery.SourceFileLoader('doctor', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)

class DoctorTests(unittest.TestCase):
    def check_flight(self, flight, binds=None):
        status = {'parked': 0, 'addresses': [], 'flight': flight, 'bar': {'placed': True}}
        binds = binds or {'installed': True, 'live': {'park': True}, 'conflicts': []}
        def run(cmd, timeout=2):
            if cmd[0] == 'hyprctl': return 0, '[]'
            if cmd[0] == 'omarchy-shell': return 0, json.dumps(status)
            if 'inspect' in cmd: return 0, '{"status":"empty"}'
            return 0, json.dumps(binds)
        output = io.StringIO()
        with patch.object(doctor, 'run', run), patch.object(doctor.shutil, 'which', return_value='/fixture/bin'), \
             patch.dict(os.environ, {'HYPRLAND_INSTANCE_SIGNATURE': 'test-session'}), \
             patch('sys.argv', ['reprieve-doctor', '--json']), contextlib.redirect_stdout(output):
            result = doctor.main()
        return result, json.loads(output.getvalue())

    def test_missing_renderer_fails_health_when_effects_enabled(self):
        rc, result = self.check_flight({'mode': 'angel', 'handler': False, 'screens': []})
        self.assertEqual(rc, 1)
        self.assertTrue(any('flight' in p.lower() for p in result['problems']))

    def test_enabled_renderer_with_no_screen_fails_health(self):
        rc, _ = self.check_flight({'mode': 'subtle', 'handler': True, 'screens': []})
        self.assertEqual(rc, 1)

    def test_loaded_renderer_and_explicit_off_are_healthy(self):
        for flight in ({'mode': 'angel', 'handler': True, 'screens': ['DP-2']}, {'mode': 'off', 'handler': False}):
            rc, result = self.check_flight(flight)
            self.assertEqual(rc, 0, result)

    def flight_row(self, result):
        return next(r for r in result['rows'] if r['label'] == 'Flight')

    def test_both_directions_off_are_healthy_whatever_the_shared_fallback(self):
        # 1.5.4 sets removal and restoration separately; the shared `flight`
        # value is only their fallback and can still read "subtle".
        rc, result = self.check_flight({'mode': 'subtle', 'parkMode': 'off', 'restoreMode': 'off',
                                        'handler': False, 'screens': []})
        self.assertEqual(rc, 0, result)
        self.assertEqual(self.flight_row(result)['value'], 'off')

    def test_one_animated_direction_needs_the_renderer(self):
        rc, result = self.check_flight({'mode': 'off', 'parkMode': 'off', 'restoreMode': 'angel',
                                        'handler': False, 'screens': []})
        self.assertEqual(rc, 1, result)
        self.assertTrue(any('flight' in p.lower() for p in result['problems']))

    def test_split_directions_are_reported_separately(self):
        rc, result = self.check_flight({'mode': 'subtle', 'parkMode': 'off', 'restoreMode': 'angel',
                                        'handler': True, 'screens': ['DP-2']})
        self.assertEqual(rc, 0, result)
        self.assertEqual(self.flight_row(result)['value'], 'removal off, restoration angel (renderer ready)')

    def test_unreadable_bindings_file_is_named(self):
        rc, result = self.check_flight({'mode': 'off'}, binds={
            'installed': False, 'live': {}, 'conflicts': [],
            'file': 'bindings.lua is not valid UTF-8 (byte 6); Reprieve will not rewrite it'})
        self.assertEqual(rc, 1)
        row = next(r for r in result['rows'] if r['label'] == 'Bindings file')
        self.assertIn('UTF-8', row['value'])
        self.assertFalse(row['ok'])

    def test_unreadable_bindings_file_does_not_advise_setup(self):
        # The block may be in the file and live; setup would refuse the file.
        rc, result = self.check_flight({'mode': 'off'}, binds={
            'installed': False, 'live': {'park': True}, 'conflicts': [],
            'file': 'bindings.lua is not valid UTF-8 (byte 6); Reprieve will not rewrite it'})
        self.assertEqual(rc, 1)
        row = next(r for r in result['rows'] if r['label'] == 'Bindings')
        self.assertEqual(row['value'], 'live')
        self.assertFalse(any('reprieve setup' in p for p in result['problems']), result['problems'])

if __name__ == '__main__': unittest.main()
