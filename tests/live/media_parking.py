#!/usr/bin/env python3
"""Qualify installed Reprieve media handling with dedicated test windows.

Restarts the shell twice and temporarily toggles pauseMediaOnPark, restoring
its effective value. Requires no user windows parked at startup. The legacy
case adds a mute record only to its own already-parked test window's journal.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave

PLUGIN = 'tech.greyforge.reprieve'


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=10).strip()


def ipc(*args):
    return run('omarchy-shell', PLUGIN, *args)


def clients():
    return json.loads(run('hyprctl', '-j', 'clients'))


def until(predicate, description):
    for _ in range(100):
        try:
            result = predicate()
            if result:
                return result
        except (subprocess.SubprocessError, ValueError, OSError):
            pass
        time.sleep(.1)
    raise RuntimeError('Timed out: ' + description)


def main():
    if any(c['workspace']['name'] == 'special:reprieve' for c in clients()):
        raise RuntimeError('Refusing to run while user windows are parked')
    settings = json.loads(ipc('settings'))
    original_pause = settings.get('pauseMediaOnPark', True)
    state_home = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state')))
    journal = state_home / 'reprieve/state.json'
    audio_state = state_home / 'wireplumber/stream-properties'
    processes = []
    addresses = []
    token = 'reprieveqa' + str(time.time_ns())

    def spawn(klass, *command):
        proc = subprocess.Popen(['foot', '--app-id=' + klass, '--title=Reprieve media qualification', *command],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        processes.append(proc)
        client = until(lambda: next((c for c in clients() if c['class'] == klass), None), 'test window')
        addresses.append(client['address'])
        return client['address']

    def entry(address):
        return next((e for e in json.loads(journal.read_text())['entries'] if e['address'] == address), {})

    def status(name):
        return run('busctl', '--user', 'get-property', name, '/org/mpris/MediaPlayer2',
                   'org.mpris.MediaPlayer2.Player', 'PlaybackStatus')

    def restart(address):
        run('omarchy', 'restart', 'shell')
        until(lambda: address in json.loads(ipc('status')).get('addresses', []), 'parked window reconciled after shell recovery')

    try:
        ipc('setSetting', 'pauseMediaOnPark', 'true')
        with tempfile.TemporaryDirectory(prefix='reprieve-media-parking-') as directory:
            directory = Path(directory)
            log = directory / 'player-events'
            name = 'org.mpris.MediaPlayer2.' + token
            addr = spawn(token, sys.executable, str(Path(__file__).with_name('audio_streams.py')),
                         '--serve-player', name, str(log))
            until(lambda: 'Playing' in status(name), 'MPRIS player ready')
            ipc('parkWindow', addr)
            until(lambda: 'Paused' in status(name), 'park pauses player')
            until(lambda: name in (entry(addr).get('media') or {}).get('paused', []), 'pause journaled')
            restart(addr)
            assert 'Paused' in status(name)
            until(lambda: name in (entry(addr).get('media') or {}).get('paused', []), 'pause recovered')
            assert ipc('restoreAddress', addr) in ('undone', 'here')
            until(lambda: 'Playing' in status(name), 'restore resumes player after shell reload')
            print('PASS: installed plugin parks/resumes MPRIS across shell reload', flush=True)

            ipc('parkWindow', addr)
            until(lambda: 'Paused' in status(name), 'second pause')
            until(lambda: name in (entry(addr).get('media') or {}).get('paused', []), 'second pause journaled')
            ipc('setSetting', 'pauseMediaOnPark', 'false')
            ipc('closeParked', addr)
            until(lambda: not any(c['address'] == addr for c in clients()), 'test player closed')
            assert log.read_text().splitlines() == ['Pause', 'Play', 'Pause', 'Play'], log.read_text()
            print('PASS: disabling new pauses preserves owed player cleanup before close', flush=True)

            # Recreate a legacy journal with only an owned silent stream muted.
            ipc('setSetting', 'pauseMediaOnPark', 'true')
            wav = directory / 'silence.wav'
            with wave.open(str(wav), 'wb') as out:
                out.setnchannels(2)
                out.setsampwidth(2)
                out.setframerate(48000)
                out.writeframes(bytes(48000 * 4 * 60))
            app = token + 'legacy'
            addr = spawn(app, 'paplay', '--client-name=' + app, str(wav))

            def stream():
                return next((s for s in json.loads(run('pactl', '-f', 'json', 'list', 'sink-inputs'))
                             if s.get('properties', {}).get('application.name') == app), None)

            sink = until(stream, 'legacy test stream')
            ipc('parkWindow', addr)
            until(lambda: entry(addr), 'legacy window journaled')
            time.sleep(1)
            run('pactl', 'set-sink-input-mute', str(sink['index']), '1')
            record = json.loads(journal.read_text())
            owned = next(e for e in record['entries'] if e['address'] == addr)
            owned['media'] = {'muted': [{'index': sink['index'],
                                        'pid': int(sink['properties']['application.process.id'])}], 'paused': []}
            fd, pending = tempfile.mkstemp(dir=journal.parent, prefix='qualification-')
            with os.fdopen(fd, 'w') as output:
                json.dump(record, output)
            os.replace(pending, journal)
            restart(addr)
            until(lambda: (entry(addr).get('media') or {}).get('muted'), 'legacy record recovered')
            ipc('setSetting', 'pauseMediaOnPark', 'false')
            ipc('closeParked', addr)
            until(lambda: not any(c['address'] == addr for c in clients()), 'legacy test window closed')

            def saved_mute():
                key = 'Output/Audio:application.name:' + app + '='
                return next((json.loads(line[len(key):]).get('mute') for line in audio_state.read_text().splitlines()
                             if line.startswith(key)), None)

            until(lambda: saved_mute() is False, 'legacy saved mute cleared before stream death')
            print('PASS: legacy mute cleanup survives reload and disabled pausing before close', flush=True)
    finally:
        ipc('setSetting', 'pauseMediaOnPark', 'true' if original_pause else 'false')
        for addr in addresses:
            client = next((c for c in clients() if c['address'] == addr), None)
            if client:
                if client['workspace']['name'] == 'special:reprieve':
                    ipc('closeParked', addr)
                else:
                    run('hyprctl', 'dispatch', f'hl.dsp.window.close({{ window = "address:{addr}" }})')
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)


if __name__ == '__main__':
    main()
