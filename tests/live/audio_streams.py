#!/usr/bin/env python3
"""Helper-level live audio regression; only controls its own silent streams/player.

Needs the desktop PipeWire/Pulse and session bus, paplay/pactl/busctl, and PyGObject.
Does not install the plugin, park real windows, or restart desktop services.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import wave


def serve_player(name, events=None):
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    xml = '''<node><interface name="org.mpris.MediaPlayer2.Player">
      <method name="Pause"/><method name="Play"/>
      <property name="PlaybackStatus" type="s" access="read"/>
    </interface></node>'''
    status = ['Playing']

    def method(connection, sender, path, interface, name, parameters, invocation):
        status[0] = 'Paused' if name == 'Pause' else 'Playing'
        if events:
            with open(events, 'a') as log:
                log.write(name + '\n')
        invocation.return_value(None)

    bus.register_object('/org/mpris/MediaPlayer2',
                        Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], method,
                        lambda *args: GLib.Variant('s', status[0]), None)
    bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                  'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', (name, 4)),
                  None, Gio.DBusCallFlags.NONE, 3000, None)
    print('ready', flush=True)
    GLib.MainLoop().run()


def main():
    helper = Path(__file__).resolve().parents[2] / 'bin/reprieve-media'
    loader = importlib.machinery.SourceFileLoader('reprieve_media', str(helper))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    media = importlib.util.module_from_spec(spec)
    loader.exec_module(media)
    app = 'reprieve-audio-test-' + str(time.time_ns())
    player_name = 'org.mpris.MediaPlayer2.' + app.replace('-', '_')
    state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'wireplumber/stream-properties'
    processes = []

    def streams():
        data = subprocess.check_output(['pactl', '-f', 'json', 'list', 'sink-inputs'], timeout=3)
        return [s for s in json.loads(data) if s.get('properties', {}).get('application.name') == app]

    def wait_stream():
        for _ in range(40):
            current = streams()
            if current:
                return current[0]
            time.sleep(.1)
        raise RuntimeError('No test playback stream appeared')

    def saved():
        key = 'Output/Audio:application.name:' + app + '='
        if not state.exists():
            return {}
        return next((json.loads(line[len(key):]) for line in state.read_text().splitlines()
                     if line.startswith(key)), {})

    try:
        with tempfile.TemporaryDirectory(prefix='reprieve-audio-') as directory:
            wav = Path(directory) / 'silence.wav'
            with wave.open(str(wav), 'wb') as output:
                output.setnchannels(2)
                output.setsampwidth(2)
                output.setframerate(48000)
                output.writeframes(bytes(48000 * 4 * 60))

            def start_stream():
                proc = subprocess.Popen(['paplay', '--client-name=' + app, str(wav)])
                processes.append(proc)
                return proc

            # Restrict discovery to our fixtures; never pause a real player.
            media.mpris_names = lambda: []
            first = start_stream()
            original = wait_stream()
            payload = media.pause(first.pid, '')
            assert payload == {'muted': [], 'paused': []}, payload
            current = wait_stream()
            assert current['mute'] == original['mute'] is False
            assert current['volume'] == original['volume'] and current['sink'] == original['sink']
            first.terminate()
            first.wait(timeout=3)
            start_stream()
            replacement = wait_stream()
            assert replacement['index'] != original['index'] and replacement['mute'] is False
            assert media.resume(payload) == {'unmuted': 0, 'played': 0}
            assert wait_stream()['mute'] is False
            # Give WirePlumber's delayed state writer time to settle.
            time.sleep(1.5)
            assert saved().get('mute', False) is False
            print('PASS: park, stream replacement, restore preserve live/saved mute and volume', flush=True)

            player = subprocess.Popen([sys.executable, __file__, '--serve-player', player_name],
                                      stdout=subprocess.PIPE, text=True)
            processes.append(player)
            with selectors.DefaultSelector() as selector:
                selector.register(player.stdout, selectors.EVENT_READ)
                if not selector.select(5) or player.stdout.readline().strip() != 'ready':
                    raise RuntimeError('Test MPRIS player did not become ready')
            media.mpris_names = lambda: [player_name]
            payload = media.pause(player.pid, app.replace('-', '_'))
            assert payload == {'muted': [], 'paused': [player_name]}, payload
            media.begin()
            assert media.mpris_status(player_name) == 'Paused'
            assert media.resume(payload) == {'unmuted': 0, 'played': 1}
            media.begin()
            assert media.mpris_status(player_name) == 'Playing'
            assert wait_stream()['mute'] is False
            print('PASS: real MPRIS Pause/Play succeeds without touching mixer mute', flush=True)
    finally:
        # Also clean up if this test is run against the regressed helper.
        try:
            for stream in streams():
                if stream['mute']:
                    subprocess.run(['pactl', 'set-sink-input-mute', str(stream['index']), '0'],
                                   check=True, timeout=3)
            time.sleep(1.5)
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
                if proc.stdout:
                    proc.stdout.close()


if __name__ == '__main__':
    if len(sys.argv) in (3, 4) and sys.argv[1] == '--serve-player':
        serve_player(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
    else:
        main()
