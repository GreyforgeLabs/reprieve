#!/usr/bin/env python3
import importlib.machinery
import unittest
from pathlib import Path

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

    def test_run_respects_deadline(self):
        mod._deadline = 0
        result = mod.run(["true"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "timeout")


if __name__ == "__main__":
    unittest.main()
