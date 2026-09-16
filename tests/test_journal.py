#!/usr/bin/env python3
"""Offline tests for bin/reprieve-journal (atomic writes, refusals, bounds)."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

JOURNAL = Path(__file__).resolve().parents[1] / "bin" / "reprieve-journal"


def run(action, state_dir, stdin=None, extra=None):
    cmd = [sys.executable, str(JOURNAL), action, "--state-dir", str(state_dir)] + (extra or [])
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=10)
    out = json.loads(proc.stdout.strip() or "{}")
    return proc.returncode, out


DOC = json.dumps({"schema": 1, "session": "abc", "sequence": 2, "entries": [
    {"address": "0x1", "workspace": "1", "class": "foot", "floating": False, "fullscreen": 0,
     "fullscreenClient": 0, "pid": 1, "sequence": 1}]})


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.state = self.base / "reprieve"

    def tearDown(self):
        self.tmp.cleanup()

    def test_read_empty(self):
        rc, out = run("read", self.state)
        self.assertEqual(rc, 0)
        self.assertEqual(out["status"], "empty")

    def test_write_creates_dir_and_file_with_restrictive_modes(self):
        rc, out = run("write", self.state, stdin=DOC)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(stat.S_IMODE(os.lstat(self.state).st_mode), 0o700)
        path = self.state / "state.json"
        self.assertEqual(stat.S_IMODE(os.lstat(path).st_mode), 0o600)
        self.assertEqual(json.loads(path.read_text())["session"], "abc")
        # No temp files left behind.
        self.assertEqual(sorted(p.name for p in self.state.iterdir()), ["state.json"])

    def test_write_is_atomic_replace(self):
        run("write", self.state, stdin=DOC)
        before = os.lstat(self.state / "state.json").st_ino
        doc2 = json.loads(DOC)
        doc2["sequence"] = 3
        rc, out = run("write", self.state, stdin=json.dumps(doc2))
        self.assertEqual(rc, 0)
        after = os.lstat(self.state / "state.json").st_ino
        self.assertNotEqual(before, after)  # rename, not in-place rewrite
        rc, out = run("read", self.state)
        self.assertEqual(json.loads(out["text"])["sequence"], 3)

    def test_write_rejects_non_json_and_oversized(self):
        rc, out = run("write", self.state, stdin="{nope")
        self.assertEqual(rc, 1)
        self.assertEqual(out["status"], "error")
        rc, out = run("write", self.state, stdin="[" + "1," * 200000 + "1]")
        self.assertEqual(rc, 1)
        self.assertFalse((self.state / "state.json").exists())

    def test_read_refuses_symlink(self):
        self.state.mkdir(mode=0o700)
        target = self.base / "victim.json"
        target.write_text('{"schema":1,"session":"abc","entries":[]}')
        os.symlink(target, self.state / "state.json")
        rc, out = run("read", self.state)
        self.assertEqual(out["status"], "symlink")
        self.assertEqual(out["text"], "")
        # Writing refuses too, and the victim is untouched.
        rc, out = run("write", self.state, stdin=DOC)
        self.assertEqual(rc, 1)
        self.assertIn("symlink", out["error"])
        self.assertEqual(json.loads(target.read_text())["session"], "abc")
        # Quarantine removes the link but never the target.
        rc, out = run("quarantine", self.state)
        self.assertEqual(out["status"], "removed")
        self.assertTrue(target.exists())
        self.assertFalse(os.path.lexists(self.state / "state.json"))

    def test_symlinked_state_dir_is_refused(self):
        real = self.base / "elsewhere"
        real.mkdir()
        os.symlink(real, self.state)
        rc, out = run("write", self.state, stdin=DOC)
        self.assertEqual(rc, 1)
        self.assertIn("symlink", out["error"])
        self.assertFalse((real / "state.json").exists())

    def test_read_refuses_oversized_and_irregular(self):
        self.state.mkdir(mode=0o700)
        big = self.state / "state.json"
        big.write_bytes(b"x" * (262144 + 1))
        rc, out = run("read", self.state)
        self.assertEqual(out["status"], "oversized")
        big.unlink()
        os.mkfifo(self.state / "state.json")
        rc, out = run("read", self.state)
        self.assertEqual(out["status"], "irregular")

    def test_read_refuses_symlinked_state_dir(self):
        target = self.base / "real-state"
        target.mkdir(mode=0o700)
        (target / "state.json").write_text(DOC)
        os.symlink(target, self.state)
        rc, out = run("read", self.state)
        self.assertEqual(out["status"], "symlink")
        self.assertEqual(out["text"], "")
        rc, out = run("quarantine", self.state)
        self.assertNotEqual(out["status"], "ok")
        # Nothing was touched through the link.
        self.assertEqual((target / "state.json").read_text(), DOC)

    def test_quarantine_moves_damaged_file_aside(self):
        self.state.mkdir(mode=0o700)
        (self.state / "state.json").write_text("{corrupt")
        rc, out = run("quarantine", self.state, extra=["--reason", "json"])
        self.assertEqual(rc, 0)
        self.assertEqual(out["status"], "ok")
        self.assertFalse((self.state / "state.json").exists())
        moved = [p for p in self.state.iterdir() if p.name.startswith("state.json.json.")]
        self.assertEqual(len(moved), 1)
        self.assertEqual(moved[0].read_text(), "{corrupt")
        rc, out = run("quarantine", self.state)
        self.assertEqual(out["status"], "empty")

    def test_inspect_is_read_only(self):
        run("write", self.state, stdin=DOC)
        mtime = os.lstat(self.state / "state.json").st_mtime_ns
        rc, out = run("inspect", self.state)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["entries"], 1)
        self.assertEqual(out["session"], "abc")
        self.assertEqual(os.lstat(self.state / "state.json").st_mtime_ns, mtime)
        (self.state / "state.json").write_text("[]")
        rc, out = run("inspect", self.state)
        self.assertEqual(out["status"], "invalid")


if __name__ == "__main__":
    unittest.main()
