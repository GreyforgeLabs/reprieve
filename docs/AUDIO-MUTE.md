# Persistent audio mute after parking

## Confirmed defect

On 2026-09-13, the media helper from the current main branch (based on 1.1.0)
was exercised against a uniquely named silent Pulse/PipeWire stream. Its
MPRIS discovery was restricted to an empty list so no real player was touched.

1. `pause` muted the test stream and recorded its stream index and PID.
2. The stream was terminated and replaced under the same application name.
3. WirePlumber restored the replacement stream with `mute:true`.
4. `resume` reported `unmuted:0` because the recorded stream index was gone.
5. The replacement remained muted, and the saved application entry was also
   `mute:true`. Test cleanup explicitly cleared and verified its own saved mute.

The exact muting code is present in tags **v1.0.0 and v1.1.0**. The default
`pauseMediaOnPark:true` enables it. This can affect any application whose
stream the helper matches by process ancestry; it is not Chromium-specific.
Stream replacement is enough to trigger it: the entire browser need not crash.
Muting before the MPRIS Pause call also makes normal stream teardown on pause
a possible trigger. The reproduction establishes the defect, not which actor
caused a particular user's earlier mute.

This is a user-visible audio availability bug. Reopening the application may
retain the saved mute. The previous qualification covered restore of the
same stream and Reprieve's own close ordering, but not replacement streams.
The historical qualification's known limitation understated that scope.

## Mitigation for released versions

Run `reprieve set pauseMediaOnPark false` to prevent new parking mute actions.
This means media can keep playing while a window is parked. It does not clear
existing saved mutes. For affected audio, start playback and unmute that
application in the Audio widget. Prefer this targeted action to restarting
the browser or resetting the whole audio stack.

Do not automatically unmute every application during an upgrade: there is
no reliable ownership record for orphaned saved mutes, and some are intentional.

## Patch

- New parks use MPRIS Pause only and never change mixer mute or volume.
- Applications without pause support may keep playing while parked.
- Matching live streams from old journal records still receive cleanup on
  restore/close. Cleanup requires a known matching PID and stream index.
- Disabling future media pausing does not skip existing cleanup before close.
- Failed Pause/Play and mixer cleanup commands are not recorded or counted
  as successful.

This prevents the persistent mixer-mute failure path for new parks. It does
not retroactively repair orphaned mutes created by released versions. Existing
MPRIS limitations remain: a browser can share one media player across windows,
and pausing is best effort. The patch does not guarantee all parked audio is silent.

## Validation and release gate

The new offline regression tests failed against the old helper. After the fix,
`tests/run.sh` passes: 25 model cases, 9 journal tests, 16 binding tests, and 8
media tests, plus the script and plugin validation checks. Live helper checks
are in `python3 tests/live/audio_streams.py`: uniquely named silent streams,
stream replacement, saved mute, and a temporary MPRIS service for real
Pause/Play calls. Both live checks passed on 2026-09-13. They never install the
plugin or control real media players.

The full window/shell acceptance matrix must still be run on the patched
installed plugin before release. Its audio cases have been changed to expect
preserved mixer state. Also qualify MPRIS park/restore, a player without
pause support, shell reload while parked, and disabling pausing with a legacy
mute record pending. This patch has not been installed into the running plugin
or published. Do not reuse the 1.0.0 qualification result as proof for this change.

Prioritize a focused bugfix release. Keep unrelated unreleased changes out of
that release. Include the changed no-pause-support behavior and the one-time
unmute instruction in its notes.

## Draft user notice

Reprieve 1.0.0 and 1.1.0 can leave application audio muted if an audio stream
disappears or is replaced while its window is parked. Until a fix is installed,
run `reprieve set pauseMediaOnPark false`; parked windows may then keep playing
audio. If an application is already silent, start playback and unmute it in
the Audio widget. Disabling parking's media handling prevents new mutes but
does not clear an existing one.
