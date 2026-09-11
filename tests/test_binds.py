#!/usr/bin/env python3
"""Offline tests for bin/reprieve-binds. Hyprland is never contacted: the
HYPRLAND_INSTANCE_SIGNATURE variable is scrubbed so conflict detection uses
the textual fallback, and --no-reload skips hyprctl."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BINDS = Path(__file__).resolve().parents[1] / "bin" / "reprieve-binds"
PLUGIN_ID = "tech.greyforge.reprieve"
BEGIN = f"-- BEGIN {PLUGIN_ID}"
END = f"-- END {PLUGIN_ID}"

USER_CONFIG = """-- personal overrides
o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")
hl.unbind("SUPER + SHIFT + B")

if os.getenv("HOME") then
  hl.layer_rule({ match = { namespace = "^(something)$" }, no_anim = true })
end
"""


def run(*args, config, home):
    env = {k: v for k, v in os.environ.items() if k != "HYPRLAND_INSTANCE_SIGNATURE"}
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    cmd = [sys.executable, str(BINDS), *args, "--json", "--config", str(config), "--no-reload"]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10, env=env)
    try:
        out = json.loads(proc.stdout.strip() or "{}")
    except ValueError:
        out = {"raw": proc.stdout, "stderr": proc.stderr}
    return proc.returncode, out


def block_of(text):
    start = text.index(BEGIN)
    end = text.index(END) + len(END)
    return text[start:end]


class BindTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        (self.home / ".config" / "hypr").mkdir(parents=True)
        (self.home / ".local" / "bin").mkdir(parents=True)
        self.config = self.home / ".config" / "hypr" / "bindings.lua"

    def tearDown(self):
        self.tmp.cleanup()

    def backups(self):
        return sorted(self.config.parent.glob("bindings.lua.bak.*"))

    def temp_files(self):
        return [p for p in self.config.parent.iterdir() if p.name.startswith(".bindings.lua.")]

    # --- install -----------------------------------------------------------

    def test_fresh_install_writes_exactly_one_marked_block(self):
        self.config.write_text(USER_CONFIG)
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["status"], "ok")
        text = self.config.read_text()
        self.assertEqual(text.count(BEGIN), 1)
        self.assertEqual(text.count(END), 1)
        self.assertTrue(text.startswith(USER_CONFIG.rstrip("\n")))
        block = block_of(text)
        self.assertIn('hl.unbind("SUPER + W")', block)
        self.assertIn('o.bind("SUPER + W", "Park window (Reprieve)"', block)
        self.assertIn('o.bind("SUPER + ALT + W", "Close window permanently"', block)
        self.assertIn(f'hl.dsp.global("{PLUGIN_ID}:undo")', block)
        self.assertIn(f'hl.dsp.global("{PLUGIN_ID}:redo")', block)
        self.assertIn(f'hl.dsp.global("{PLUGIN_ID}:timeline")', block)
        self.assertIn('workspace = "special:reprieve"', block)
        # Free keys are not unbound: no stomping.
        self.assertNotIn('hl.unbind("SUPER + Z")', block)
        self.assertNotIn('hl.unbind("SUPER + Y")', block)
        self.assertEqual(out["conflicts"], [])
        self.assertEqual(out["skipped"], [])
        self.assertEqual(out["keys"]["undo"], "Super+Z")
        self.assertEqual(self.temp_files(), [])

    def test_install_creates_missing_config(self):
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.config.read_text().startswith(BEGIN))
        self.assertIsNone(out["backup"])

    def test_idempotent_install(self):
        self.config.write_text(USER_CONFIG)
        run("install", config=self.config, home=self.home)
        first = self.config.read_text()
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 0)
        self.assertEqual(self.config.read_text(), first)
        self.assertEqual(self.config.read_text().count(BEGIN), 1)

    def test_backup_and_atomic_replacement(self):
        self.config.write_text(USER_CONFIG)
        before_inode = os.lstat(self.config).st_ino
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_text(), USER_CONFIG)
        self.assertEqual(out["backup"], str(self.backups()[0]))
        self.assertNotEqual(os.lstat(self.config).st_ino, before_inode)
        self.assertEqual(self.temp_files(), [])

    def test_symlink_refusal(self):
        real = self.home / "real.lua"
        real.write_text(USER_CONFIG)
        self.config.symlink_to(real)
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertIn("symlink", out["error"])
        self.assertEqual(real.read_text(), USER_CONFIG)
        self.assertTrue(self.config.is_symlink())
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        rc, out = run("status", config=self.config, home=self.home)
        self.assertIn("symlink", out["file"])

    def test_regular_file_refusal(self):
        self.config.mkdir()
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertIn("not a regular file", out["error"])
        self.assertTrue(self.config.is_dir())

    # --- conflicts ---------------------------------------------------------

    def test_occupied_super_z_is_skipped_not_stomped(self):
        self.config.write_text(USER_CONFIG + 'o.bind("SUPER + Z", "My zoom", "zoomer")\n')
        rc, status = run("status", config=self.config, home=self.home)
        self.assertEqual([c["action"] for c in status["conflicts"]], ["undo"])
        self.assertEqual(status["conflicts"][0]["owner"], "My zoom")
        self.assertEqual(status["conflicts"][0]["alternate"], "SUPER + ALT + Z")

        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["skipped"], ["undo"])
        self.assertEqual(out["conflicts"][0]["key"], "SUPER + Z")
        text = self.config.read_text()
        self.assertIn('o.bind("SUPER + Z", "My zoom", "zoomer")', text)
        block = block_of(text)
        self.assertNotIn('"SUPER + Z"', block)
        self.assertIn(f'hl.dsp.global("{PLUGIN_ID}:redo")', block)

    def test_occupied_super_z_alternate_key(self):
        self.config.write_text(USER_CONFIG + 'o.bind("SUPER + Z", "My zoom", "zoomer")\n')
        rc, out = run("install", "--undo", "SUPER + ALT + Z", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["keys"]["undo"], "Super+Alt+Z")
        block = block_of(self.config.read_text())
        self.assertIn(f'o.bind("SUPER + ALT + Z", "Restore parked window", hl.dsp.global("{PLUGIN_ID}:undo"))', block)
        self.assertNotIn('hl.unbind("SUPER + Z")', block)

    def test_occupied_super_z_explicit_replace(self):
        self.config.write_text(USER_CONFIG + 'o.bind("SUPER + Z", "My zoom", "zoomer")\n')
        rc, out = run("install", "--replace", "undo", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        block = block_of(self.config.read_text())
        self.assertIn('hl.unbind("SUPER + Z")', block)
        self.assertIn(f'hl.dsp.global("{PLUGIN_ID}:undo")', block)
        self.assertEqual(out["unbound"][0]["owner"], "My zoom")
        # The user's own line is still there (unbind happens at runtime, in our block).
        self.assertIn('o.bind("SUPER + Z", "My zoom", "zoomer")', self.config.read_text())

    def test_custom_super_w_requires_explicit_replace(self):
        self.config.write_text(USER_CONFIG + 'o.bind("SUPER + W", "Web", { launch = "chromium" })\n')
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 3)
        self.assertEqual(out["status"], "conflict")
        self.assertEqual(out["conflicts"][0]["action"], "park")
        self.assertEqual(out["conflicts"][0]["owner"], "Web")
        self.assertNotIn(BEGIN, self.config.read_text())
        self.assertEqual(self.backups(), [])
        rc, out = run("install", "--replace", "park", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertIn(BEGIN, self.config.read_text())

    def test_invalid_key_rejected(self):
        self.config.write_text(USER_CONFIG)
        rc, out = run("install", "--undo", 'Z"); os.execute("id', config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertNotIn(BEGIN, self.config.read_text())
        rc, out = run("install", "--undo", "CTRL + Z", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertIn("SUPER", out["error"])
        rc, out = run("install", "--undo", "SUPER + Y", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertIn("both", out["error"])

    def test_malformed_marker_block_is_refused(self):
        broken = USER_CONFIG + f"\n{BEGIN}\no.bind(\"SUPER + W\", \"x\", \"y\")\n"  # no END
        self.config.write_text(broken)
        rc, status = run("status", config=self.config, home=self.home)
        self.assertIn(PLUGIN_ID, status["malformed"])
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertIn("unbalanced", out["error"])
        self.assertEqual(self.config.read_text(), broken)
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(rc, 1)
        self.assertEqual(self.config.read_text(), broken)

    # --- removal -----------------------------------------------------------

    def test_remove_is_exact_and_idempotent(self):
        self.config.write_text(USER_CONFIG)
        run("install", config=self.config, home=self.home)
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["removed"], 1)
        self.assertEqual(self.config.read_text().rstrip("\n"), USER_CONFIG.rstrip("\n"))
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(rc, 0)
        self.assertEqual(out["removed"], 0)
        self.assertEqual(self.config.read_text().rstrip("\n"), USER_CONFIG.rstrip("\n"))
        rc, out = run("remove", config=self.home / "nope.lua", home=self.home)
        self.assertEqual(rc, 0)

    def test_no_unrelated_config_loss_through_full_cycle(self):
        original = USER_CONFIG + "\n-- trailing comment\n"
        self.config.write_text(original)
        run("install", config=self.config, home=self.home)
        run("install", "--redo", "SUPER + ALT + Y", config=self.config, home=self.home)
        run("remove", config=self.config, home=self.home)
        final = self.config.read_text()
        self.assertIn(USER_CONFIG.rstrip("\n"), final)
        self.assertIn("-- trailing comment", final)
        self.assertNotIn(BEGIN, final)

    def test_user_config_is_byte_identical_after_install_and_remove(self):
        for original in (USER_CONFIG, USER_CONFIG + "\n\n\n", "-- one\n\n\n\n-- two\n", "no trailing newline"):
            self.config.write_text(original)
            run("install", config=self.config, home=self.home)
            self.assertTrue(self.config.read_text().startswith(original))
            run("remove", config=self.config, home=self.home)
            expected = original if original.endswith("\n") else original + "\n"
            self.assertEqual(self.config.read_text(), expected)

    # --- cli link ----------------------------------------------------------

    def test_cli_link_created_and_removed_without_clobbering(self):
        self.config.write_text(USER_CONFIG)
        link = self.home / ".local" / "bin" / "reprieve"
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(out["cli_link"], "ok")
        self.assertTrue(link.is_symlink())
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(out["cli_link"], "removed")
        self.assertFalse(link.exists())
        link.write_text("#!/bin/sh\necho mine\n")
        rc, out = run("install", config=self.config, home=self.home)
        self.assertEqual(out["cli_link"], "foreign")
        self.assertEqual(link.read_text(), "#!/bin/sh\necho mine\n")
        rc, out = run("remove", config=self.config, home=self.home)
        self.assertEqual(out["cli_link"], "absent")
        self.assertTrue(link.exists())


if __name__ == "__main__":
    unittest.main()
