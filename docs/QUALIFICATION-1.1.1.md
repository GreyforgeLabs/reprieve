# Reprieve 1.1.1 qualification

Date: 2026-09-13. Machine: greyarch, Omarchy shell `4.0.0.alpha`, Hyprland
0.56.2, PipeWire 1.6.8. Release base: v1.1.0. The installed candidate was
commit `8b69f1d`; subsequent release commits change tests, documentation, and
tag CI only. Runtime files and the 1.1.1 manifest are unchanged from the
candidate used for the live checks.

| Check | Result |
| --- | --- |
| Offline suite (`tests/run.sh`) | 25 model, 9 journal, 20 binding, 8 media tests passed; script and plugin validation passed |
| Full installed-plugin matrix (`tests/live/acceptance.sh`) | **35 passed, 0 failed**, including two shell restarts and damaged-journal recovery |
| Silent stream replacement (`tests/live/audio_streams.py`) | Live and saved mute preserved across park, stream death/replacement, and restore; volume/output preserved |
| Real MPRIS helper Pause/Play | Passed with a dedicated temporary player; real user players excluded |
| Installed MPRIS park/restore across shell reload (`tests/live/media_parking.py`) | Passed; pause record recovered and playback resumed |
| Disable pausing before closing a parked player | Passed; owed Play occurred before close |
| Legacy muted stream, reload, disable pausing, close | Passed; matching old record cleaned up and saved mute was false after the stream died |

The original bug was reproduced first against the old helper with uniquely
named silent streams. Replacement inherited mute, restore reported zero
unmutes, and WirePlumber retained `mute:true`. Test cleanup cleared its own mute.
New offline regression cases failed before the fix and passed afterward.

Initial acceptance runs exposed test timing assumptions: active-window
sampling could miss the restore's focus event, startup status could precede
journal reconciliation, and a pending journal write could overwrite the test's
deliberate corruption. The final run observes Hyprland's focus event directly,
waits for recovered model state, and lets the prior journal write settle.
Direct focus probes also confirmed successful restore. No production focus or
recovery code was changed to accommodate those tests.

The test harness now refuses to start with user windows parked and only closes
its own fixtures in cleanup. It preserves pre-existing quarantine files. During
qualification an external wrapper backed up and temporarily restored the one
existing parked Chromium window, then returned it to its original parked state.

Behavior change: media without MPRIS pause support may keep playing while
parked. Previously orphaned application mutes require one targeted user unmute;
this release does not guess ownership or globally reset mute settings.
