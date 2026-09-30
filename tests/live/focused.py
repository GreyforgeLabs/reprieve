#!/usr/bin/env python3
"""Scoped live regression checks. Only act on windows created by this run.
No clear/reset/restart, no user-window closes; temporarily changes plugin
settings only when no user windows are parked, and restores those settings.
"""
import json
import os
from pathlib import Path
import subprocess
import time

PLUGIN = 'tech.greyforge.reprieve'
HERE = Path(__file__).resolve().parents[2]
ARTIFACTS = Path(os.environ.get('REPRIEVE_TEST_ARTIFACTS', '/tmp/reprieve-focused'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)

def output(*args):
    return subprocess.check_output(args, text=True, timeout=4).strip()
def ipc(*args):
    return output('omarchy-shell', PLUGIN, *args)
def status():
    return json.loads(ipc('status'))
def clients():
    return json.loads(output('hyprctl', '-j', 'clients'))
def client(address):
    return next((c for c in clients() if c['address'] == address), None)
def wait(predicate, seconds=3):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('condition timed out')
def disp(code):
    output('hyprctl', 'dispatch', code)
def setting(key, value):
    response = ipc('setSetting', key, str(value))
    assert response == 'ok', f'{key}={value}: {response}'
    time.sleep(.8)  # shell configuration watcher + recovery reconciliation

shot_screen = ''

def shot(name):
    subprocess.run(['grim', '-o', shot_screen, str(ARTIFACTS / (name + '.png'))], check=True, timeout=4)

def film(kind, address, shortcut=False):
    shot(kind + '-before')
    before = status()['flight']['flown']
    if shortcut:
        disp(f'hl.dsp.focus({{ window = "address:{address}" }})')
        wait(lambda: json.loads(output('hyprctl', '-j', 'activewindow')).get('address') == address)
        bindings = json.loads(output('hyprctl', '-j', 'binds'))
        binding = next(b for b in bindings if b['key'].upper() == 'W' and b['modmask'] == 64
                       and b['description'] == 'Park window (Reprieve)')
        subprocess.run([str(HERE / 'bin/reprieve'), 'park'], check=True, timeout=4)
    else:
        assert ipc('parkWindow' if kind == 'park' else 'restoreAddress', address) in ('parked', 'undone')
    start = time.monotonic()
    for i in range(14):
        time.sleep(max(0, start + i * .1 - time.monotonic()))
        shot(f'{kind}-{i:02d}')
    (ARTIFACTS / (kind + '-status.json')).write_text(json.dumps(status(), indent=2))
    wait(lambda: status()['flight']['flown'] > before)
    assert status()['flight']['pending'] == 0

owned = []
saved = json.loads(ipc('settings'))
assert status()['parked'] == 0, 'refusing to change timeout with user windows parked'
assert not any(c['workspace']['name'] == 'special:reprieve' for c in clients()), 'hidden workspace occupied'
focused = json.loads(output('hyprctl', '-j', 'activewindow')).get('address')

def spawn():
    process = subprocess.Popen(['foot', '--app-id=reprieve-focused', '--title=Reprieve focused test',
                                'sh', '-c', "printf '\\033[44m\\033[2J\\033[HREPRIEVE MOTION TEST'; sleep 120"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    owned.append((process, None))
    wait(lambda: any(c['pid'] == process.pid for c in clients()))
    address = next(c['address'] for c in clients() if c['pid'] == process.pid)
    owned[-1] = (process, address)
    return address

try:
    setting('parkTimeout', 0)
    setting('flight', 'angel')
    address = spawn()
    workspace = client(address)['workspace']['name']
    monitors = json.loads(output('hyprctl', '-j', 'monitors'))
    shot_screen = next(m['name'] for m in monitors if m['id'] == client(address)['monitor'])
    disp(f'hl.dsp.window.float({{ window = "address:{address}", action = "enable" }})')
    time.sleep(.3)
    disp(f'hl.dsp.window.resize({{ window = "address:{address}", x = 600, y = 400, relative = false }})')
    time.sleep(.3)
    assert client(address)['size'] == [600, 400]
    (ARTIFACTS / 'geometry-before.json').write_text(json.dumps(client(address), indent=2))
    film('park', address, shortcut=os.environ.get('REPRIEVE_TEST_SHORTCUT') == '1')
    assert client(address)['workspace']['name'] == 'special:reprieve'
    print('PASS scoped park (captured motion needs visual review)', flush=True)
    film('restore', address)
    assert client(address)['workspace']['name'] == workspace
    assert client(address)['floating'] is True
    print('PASS restore, original workspace, floating state', flush=True)
    before = status()['flight']['flown']
    assert ipc('redo') == 'redone'
    wait(lambda: status()['flight']['flown'] > before)
    assert client(address)['workspace']['name'] == 'special:reprieve'
    assert ipc('restoreAddress', address) == 'undone'
    wait(lambda: client(address)['workspace']['name'] == workspace)
    time.sleep(.5)
    print('PASS redo completes a park flight', flush=True)
    for i in range(8):
        response = ipc('parkWindow', address)
        assert response == 'parked', (response, client(address), status())
        ipc('parkWindow', address)  # repeat while the first flight is pending
        assert ipc('restoreAddress', address) == 'undone'
        time.sleep(.2)
    wait(lambda: status()['flight']['pending'] == 0)
    time.sleep(1.7)  # allow any incorrectly retained cuts to fire
    assert client(address)['workspace']['name'] == workspace
    assert address not in status()['addresses']
    assert status()['stranded'] == 0
    print('PASS rapid duplicate park/restore cannot strand the window', flush=True)
    disp(f'hl.dsp.window.fullscreen_state({{ window = "address:{address}", internal = 1, client = 1, action = "set" }})')
    time.sleep(.5)
    ipc('parkWindow', address)
    wait(lambda: client(address)['workspace']['name'] == 'special:reprieve')
    assert client(address)['fullscreen'] == 0
    ipc('restoreAddress', address)
    wait(lambda: client(address)['workspace']['name'] == workspace)
    assert client(address)['fullscreen'] == 1
    assert client(address)['fullscreenClient'] == 1
    disp(f'hl.dsp.window.fullscreen_state({{ window = "address:{address}", internal = 0, client = 0, action = "set" }})')
    print('PASS fullscreen park/restore state', flush=True)
    setting('parkTimeout', 5)
    expired = spawn()
    began = time.monotonic()
    ipc('parkWindow', expired)
    wait(lambda: client(expired) is None, seconds=8)
    assert time.monotonic() - began >= 4.8, 'expired prematurely'
    assert expired not in status()['addresses']
    print('PASS timeout closes its disposable window at the deadline', flush=True)
    restored = spawn()
    ipc('parkWindow', restored)
    time.sleep(1)
    ipc('restoreAddress', restored)
    wait(lambda: client(restored)['workspace']['name'] != 'special:reprieve')
    time.sleep(6)
    assert client(restored), 'restored window expired'
    print('PASS restoring cancels expiry', flush=True)
    setting('parkTimeout', 0)
    grace = spawn()
    ipc('parkWindow', grace)
    time.sleep(2)
    setting('parkTimeout', 5)
    time.sleep(1)
    assert client(grace), 'lost grace interval on config reload'
    state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'reprieve/state.json'
    entry = next(e for e in json.loads(state.read_text())['entries'] if e['address'] == grace)
    assert entry['parkedAt'] > 0
    wait(lambda: client(grace) is None, seconds=7)
    print('PASS enabling timeout grants and persists grace across configuration reload', flush=True)
finally:
    for process, address in owned:
        live = client(address) if address else None
        if live and live['pid'] == process.pid:
            ipc('restoreAddress', address)
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
    for key in ('parkTimeout', 'flight'):
        setting(key, saved.get(key, 0 if key == 'parkTimeout' else 'angel'))
    if focused and client(focused):
        disp(f'hl.dsp.focus({{ window = "address:{focused}" }})')
assert status()['parked'] == 0
assert status()['stranded'] == 0
print('PASS cleanup; original settings restored', flush=True)
