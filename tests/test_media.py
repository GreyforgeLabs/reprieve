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
        with patch.object(mod, "window_pids", return_value={5868}), \
             patch.object(mod, "mpris_names", return_value=[]), \
             patch.object(mod, "run", side_effect=run):
            self.assertEqual(mod.pause(5868, "chromium"), {"muted": [], "paused": []})
        self.assertFalse(any(cmd[0] == "pactl" for cmd in calls))

    def test_pause_records_only_successful_player_commands(self):
        names = ["org.mpris.MediaPlayer2.chromium.good", "org.mpris.MediaPlayer2.chromium.failed"]
        with patch.object(mod, "window_pids", return_value={5868}), \
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

    def test_mpris_names_lists_owned_names_in_one_call(self):
        listing = ('as 5 "org.freedesktop.DBus" ":1.7" "org.mpris.MediaPlayer2.spotify" '
                   '"org.mpris.MediaPlayer2.chromium.instance5868" "org.mpris.MediaPlayer2.spotify"\n')
        calls = []
        def run(cmd):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, listing, "")
        with patch.object(mod, "run", side_effect=run):
            names = mod.mpris_names()
        self.assertEqual(names, ["org.mpris.MediaPlayer2.spotify", "org.mpris.MediaPlayer2.chromium.instance5868"])
        self.assertEqual(len(calls), 1)
        # `busctl list` includes activatable names; reading a property of
        # one would start that service.
        self.assertIn("ListNames", calls[0])
        self.assertNotIn("list", calls[0])

    def test_pause_without_players_skips_process_scan(self):
        with patch.object(mod, "mpris_names", return_value=[]), \
             patch.object(mod, "window_pids") as scan, \
             patch.object(mod, "mpris_status") as status:
            self.assertEqual(mod.pause(5868, "foot"), {"muted": [], "paused": []})
        scan.assert_not_called()
        status.assert_not_called()

    def test_pause_queries_only_matching_players(self):
        names = ["org.mpris.MediaPlayer2.spotify", "org.mpris.MediaPlayer2.chromium.instance5868",
                 "org.mpris.MediaPlayer2.mpv"]
        with patch.object(mod, "mpris_names", return_value=names), \
             patch.object(mod, "window_pids", return_value={5868}), \
             patch.object(mod, "mpris_status", return_value="Playing") as status, \
             patch.object(mod, "mpris_call", return_value=True):
            self.assertEqual(mod.pause(5868, "foot"), {"muted": [], "paused": [names[1]]})
        status.assert_called_once_with(names[1])

    def test_window_pids_walks_only_named_candidates(self):
        import os
        tree = subprocess.Popen(["sh", "-c", "sleep 30 & echo $!; wait"], stdout=subprocess.PIPE, text=True)
        try:
            grandchild = int(tree.stdout.readline())
            names = [
                f"org.mpris.MediaPlayer2.chromium.instance{tree.pid}",
                f"org.mpris.MediaPlayer2.mpv.instance_1_{grandchild}",
                f"org.mpris.MediaPlayer2.leading.instance0{tree.pid}",
                f"org.mpris.MediaPlayer2.parent.instance{os.getppid()}",
                "org.mpris.MediaPlayer2.init.instance1",
                "org.mpris.MediaPlayer2.gone.instance99999999",
            ]
            self.assertEqual(mod.window_pids(os.getpid(), names), {tree.pid, grandchild})
            self.assertEqual(mod.window_pids(tree.pid, names), {tree.pid, grandchild})
            self.assertEqual(mod.window_pids(0, names), set())
            # Same answers player_matches gives with the whole process tree.
            for name in names:
                self.assertEqual(mod.player_matches(name, mod.window_pids(tree.pid, names), "foot"),
                                 mod.player_matches(name, {tree.pid, grandchild}, "foot"), name)
        finally:
            tree.kill()
            subprocess.run(["kill", str(grandchild)], check=False)
            tree.wait()

    def test_run_respects_deadline(self):
        mod._deadline = 0
        result = mod.run(["true"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "timeout")


if __name__ == "__main__":
    unittest.main()
