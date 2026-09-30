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
    def check_flight(self, flight):
        status = {'parked': 0, 'addresses': [], 'flight': flight, 'bar': {'placed': True}}
        def run(cmd, timeout=2):
            if cmd[0] == 'hyprctl': return 0, '[]'
            if cmd[0] == 'omarchy-shell': return 0, json.dumps(status)
            if 'inspect' in cmd: return 0, '{"status":"empty"}'
            return 0, '{"installed":true,"live":{"park":true},"conflicts":[]}'
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

if __name__ == '__main__': unittest.main()
