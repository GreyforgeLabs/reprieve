#!/usr/bin/env python3
"""Compare the native journal with the original Python implementation."""
import json
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ["python3", str(ROOT / "bin/reprieve-journal.py")]
NATIVE = [str(ROOT / "bin/reprieve-journal-native")]
LAUNCHER = [str(ROOT / "bin/reprieve-journal")]
DOC = json.dumps({"schema": 1, "session": "benchmark", "entries": [
    {"address": f"0x{i:x}", "class": "terminal", "workspace": "1"}
    for i in range(64)
]})


def measure(command, action, state, repetitions=60):
    times = []
    cpu = []
    for _ in range(repetitions):
        start = time.perf_counter_ns()
        proc = subprocess.Popen(command + [action, "--state-dir", str(state)],
                                stdin=subprocess.PIPE if action == "write" else subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if action == "write":
            proc.stdin.write(DOC.encode())
            proc.stdin.close()
        _, status, usage = os.wait4(proc.pid, 0)
        if status != 0:
            raise RuntimeError(f"{command} {action} exited {status}: {proc.stderr.read().decode()}")
        times.append((time.perf_counter_ns() - start) / 1e6)
        cpu.append((usage.ru_utime + usage.ru_stime) * 1000)
        proc.stderr.close()
    return statistics.median(times), statistics.median(cpu)


def main():
    if not Path(NATIVE[0]).is_file():
        raise SystemExit("Run make native first")
    with tempfile.TemporaryDirectory() as tmp:
        state = Path(tmp) / "reprieve"
        state.mkdir(mode=0o700)
        (state / "state.json").write_text(DOC)
        for action in ("read", "write"):
            old_ms, old_cpu = measure(PYTHON, action, state)
            new_ms, new_cpu = measure(LAUNCHER, action, state)
            print(f"{action}: Python {old_ms:.2f} ms / {old_cpu:.2f} ms CPU; "
                  f"C via launcher {new_ms:.2f} ms / {new_cpu:.2f} ms CPU; "
                  f"{old_ms/new_ms:.1f}x lower latency, {old_cpu/new_cpu:.1f}x less CPU")


if __name__ == "__main__":
    main()
