#!/usr/bin/env python3
"""Undo once and verify Hyprland actually focused the expected window.

Observe the event itself so a later pointer move or overlay cannot replace
the evidence before the acceptance script queries activewindow.
"""
import os
import socket
import subprocess
import sys
import time

address = sys.argv[1].removeprefix('0x')
path = (os.environ['XDG_RUNTIME_DIR'] + '/hypr/' +
        os.environ['HYPRLAND_INSTANCE_SIGNATURE'] + '/.socket2.sock')
with socket.socket(socket.AF_UNIX) as stream:
    stream.connect(path)
    stream.settimeout(.2)
    result = subprocess.check_output(['omarchy-shell', 'tech.greyforge.reprieve', 'undo'],
                                     text=True, timeout=5).strip()
    if result not in ('undone', 'here'):
        raise SystemExit('Undo failed: ' + result)
    pending = ''
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            data = stream.recv(65536)
        except TimeoutError:
            continue
        if not data:
            break
        pending += data.decode()
        while '\n' in pending:
            line, pending = pending.split('\n', 1)
            if line == 'activewindowv2>>' + address:
                print('Hyprland confirmed focus on restored window')
                raise SystemExit(0)
    raise SystemExit('No focus event for restored window ' + address)
