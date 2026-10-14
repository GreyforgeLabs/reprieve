#!/usr/bin/env python3
"""Count process spawns and time the Super+W helper paths offline.

    python3 tests/bench_helpers.py [PLUGIN_DIR]

Stubs `omarchy-shell`, `hyprctl` and `busctl` on PATH (each logs its argv),
and wraps `readlink`, `dirname` and `timeout` so their launches are counted
too. Nothing talks to the live compositor, shell or session bus.

  * wrapper: `bin/reprieve park` against a shell that answers "parked";
  * media:   `bin/reprieve-media pause` for a terminal window while four
             MPRIS players are on the bus, one of them playing for an
             unrelated application.
"""
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]).resolve()
RUNS = int(os.environ.get("BENCH_RUNS", "41"))

PLAYERS = ["org.mpris.MediaPlayer2.spotify", "org.mpris.MediaPlayer2.chromium.instance4242",
           "org.mpris.MediaPlayer2.mpv", "org.mpris.MediaPlayer2.firefox.instance_1_77"]

LOGGER = """#!/bin/sh
printf '%s\\n' "$(basename "$0") $*" >> "$SPAWN_LOG"
"""


def write(path, text):
    path.write_text(text)
    path.chmod(0o755)


def make_stubs(stub, count_coreutils):
    log_cmd = 'printf \'%s\\n\' "$(basename "$0") $*" >> "$SPAWN_LOG"'
    write(stub / "omarchy-shell", LOGGER + 'echo parked\n')
    write(stub / "hyprctl", LOGGER)
    # busctl: `list` (old), `call ... ListNames` (new), get-property, call Pause.
    busctl = LOGGER + """case "$*" in
  *" list"*) printf 'NAME PID PROCESS\\n'; for n in %s; do printf '%%s 1 x\\n' "$n"; done ;;
  *ListNames*) printf 'as %d'; for n in %s; do printf ' "%%s"' "$n"; done; printf '\\n' ;;
  *get-property*spotify*) echo 's "Playing"' ;;
  *get-property*) echo 's "Stopped"' ;;
esac
""" % (" ".join(PLAYERS), len(PLAYERS), " ".join(PLAYERS))
    write(stub / "busctl", busctl)
    # Counted pass-throughs for the coreutils the wrapper may launch. They
    # add their own startup, so wall times come from a pass without them.
    for tool in ("readlink", "dirname", "timeout") if count_coreutils else ():
        real = shutil.which(tool)
        # The logger runs in a subshell so it cannot consume the wrapped
        # tool's stdin; `exec` keeps the real exit status (timeout's 124).
        write(stub / tool, f'#!/bin/sh\n({log_cmd}) </dev/null\nexec {real} "$@"\n')


def measure(cmd, env, cwd):
    times, counts = [], []
    log = Path(env["SPAWN_LOG"])
    for _ in range(RUNS):
        log.write_text("")
        start = time.perf_counter_ns()
        subprocess.run(cmd, env=env, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        times.append((time.perf_counter_ns() - start) / 1e6)
        counts.append(len([l for l in log.read_text().splitlines() if l]))
    return statistics.median(times), statistics.median(counts), log.read_text().split("\n")


def main():
    park = ["bash", str(ROOT / "bin/reprieve"), "park"]
    pause = ["python3", str(ROOT / "bin/reprieve-media"), "pause", "--pid", str(os.getpid()), "--class-name", "foot"]
    with tempfile.TemporaryDirectory() as tmp:
        counted, timed = Path(tmp) / "counted", Path(tmp) / "timed"
        for stub, count in ((counted, True), (timed, False)):
            stub.mkdir()
            make_stubs(stub, count)
        env = lambda stub: dict(os.environ, PATH=f"{stub}:{os.environ['PATH']}", SPAWN_LOG=str(Path(tmp) / "log"))
        _, n, last = measure(park, env(counted), tmp)
        ms, _, _ = measure(park, env(timed), tmp)
        print(f"wrapper park : {n:.0f} launches ({', '.join(l.split()[0] for l in last if l)}), median {ms:.2f} ms")
        ms, n, _ = measure(pause, env(timed), tmp)
        print(f"media pause  : {n:.0f} busctl launches, median {ms:.2f} ms")


if __name__ == "__main__":
    main()
