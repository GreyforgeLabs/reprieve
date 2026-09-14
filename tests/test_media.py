#!/usr/bin/env python3
import importlib.machinery
import unittest
import subprocess
from pathlib import Path
from unittest.mock import patch

MEDIA = Path(__file__).resolve().parents[1] / "bin" / "reprieve-media"
import importlib.util
spec = importlib.util.spec_from_loader("reprieve_media", importlib.machinery.SourceFileLoader("reprieve_media", str(MEDIA)))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


FIXTURE = """
Sink Input #12
	Mute: no
	Properties:
		application.name = "Chromium"
		application.process.id = "5868"
		application.process.binary = "chrome"
Sink Input #13
	Mute: yes
	Properties:
		application.name = "Spotify"
		application.process.id = "9000"
		application.process.binary = "spotify"
Sink Input #14
	Mute: no
	Properties:
		application.name = "Ghostty"
		application.process.id = "111"
		application.process.binary = "ghostty"
"""


class MediaTests(unittest.TestCase):
    def test_pause_does_not_change_persistent_mixer_state(self):
        calls = []
        def run(cmd):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, FIXTURE, "")
        with patch.object(mod, "descendants", return_value={5868}), \
             patch.object(mod, "mpris_names", return_value=[]), \
             patch.object(mod, "run", side_effect=run):
            self.assertEqual(mod.pause(5868, "chromium"), {"muted": [], "paused": []})
        self.assertFalse(any(cmd[0] == "pactl" for cmd in calls))

    def test_pause_records_only_successful_player_commands(self):
        names = ["org.mpris.MediaPlayer2.chromium.good", "org.mpris.MediaPlayer2.chromium.failed"]
        with patch.object(mod, "descendants", return_value={5868}), \
             patch.object(mod, "mpris_names", return_value=names), \
             patch.object(mod, "mpris_status", return_value="Playing"), \
             patch.object(mod, "mpris_call", side_effect=[True, False]), \
             patch.object(mod, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            self.assertEqual(mod.pause(5868, "chromium"), {"muted": [], "paused": names[:1]})

    def test_resume_mpris_only_does_not_require_mixer(self):
        with patch.object(mod, "run") as run, \
             patch.object(mod, "mpris_status", return_value="Paused"), \
             patch.object(mod, "mpris_call", return_value=True) as call:
            result = mod.resume({"muted": [], "paused": ["org.mpris.MediaPlayer2.chromium"]})
        run.assert_not_called()
        call.assert_called_once_with("org.mpris.MediaPlayer2.chromium", "Play")
        self.assertEqual(result, {"unmuted": 0, "played": 1})

    def test_resume_does_not_claim_failed_commands_succeeded(self):
        def run(cmd):
            return subprocess.CompletedProcess(cmd, 0 if cmd[1] == "list" else 1, FIXTURE, "")
        with patch.object(mod, "run", side_effect=run), \
             patch.object(mod, "mpris_status", return_value="Paused"), \
             patch.object(mod, "mpris_call", return_value=False):
            result = mod.resume({"muted": [{"index": 12, "pid": 5868}], "paused": ["org.mpris.MediaPlayer2.chromium"]})
        self.assertEqual(result, {"unmuted": 0, "played": 0})

    def test_legacy_cleanup_requires_exact_known_pid_and_stream(self):
        for index, pid, expected in [(12, 5868, 1), (99, 5868, 0), (12, 7, 0), (12, 0, 0)]:
            with self.subTest(index=index, pid=pid):
                calls = []
                def run(cmd):
                    calls.append(cmd)
                    return subprocess.CompletedProcess(cmd, 0, FIXTURE, "")
                with patch.object(mod, "run", side_effect=run):
                    result = mod.resume({"muted": [{"index": index, "pid": pid}]})
                self.assertEqual(result["unmuted"], expected)
                self.assertEqual(sum(cmd[1] == "set-sink-input-mute" for cmd in calls), expected)

    def test_parse_sink_inputs(self):
        sinks = mod.parse_sink_inputs(FIXTURE)
        self.assertEqual(len(sinks), 3)
        self.assertEqual(sinks[0]["index"], 12)
        self.assertEqual(sinks[0]["pid"], 5868)
        self.assertFalse(sinks[0]["mute"])
        self.assertTrue(sinks[1]["mute"])
        self.assertEqual(sinks[2]["binary"], "ghostty")

    def test_player_matches_pid_and_class(self):
        self.assertTrue(mod.player_matches("org.mpris.MediaPlayer2.chromium.instance5868", {5868}, "google-chrome"))
        self.assertTrue(mod.player_matches("org.mpris.MediaPlayer2.spotify", {1}, "Spotify"))
        self.assertFalse(mod.player_matches("org.mpris.MediaPlayer2.spotify", {1}, "com.mitchellh.ghostty"))
        # A PID must match as a whole number, not as a substring of a longer ID.
        self.assertFalse(mod.player_matches("org.mpris.MediaPlayer2.chromium.instance5868", {86}, "foot"))
        self.assertFalse(mod.player_matches("org.mpris.MediaPlayer2.chromium.instance5868", {586}, "foot"))
        self.assertFalse(mod.player_matches("org.mpris.MediaPlayer2.chromium.instance5868", {68}, "foot"))

    def test_run_respects_deadline(self):
        mod._deadline = 0
        result = mod.run(["true"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "timeout")


if __name__ == "__main__":
    unittest.main()
