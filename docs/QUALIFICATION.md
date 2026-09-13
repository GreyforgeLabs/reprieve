# Reprieve 1.0.0 — live qualification record

This is a historical record, not qualification of the current source. The
2026-09-13 [audio incident](AUDIO-MUTE.md) confirmed a persistent mute bug on
stream replacement that the original media cases did not cover. Current
acceptance expectations preserve mixer mute. See the separate
[1.1.1 qualification](QUALIFICATION-1.1.1.md) for the new run.

| | |
| --- | --- |
| Date | 2026-09-11 |
| Machine | greyarch (Omarchy 4.0.3-1, shell `4.0.0.alpha`) |
| Hyprland | 0.56.2 (`efb50993`), Lua config |
| Quickshell | 0.3.1 |
| Reprieve code under test | the `v1.0.0` tag (product files byte-identical to the tree the matrix ran on; only `tests/live/acceptance.sh` cleanup and this document were touched afterwards) |
| Install method | `omarchy plugin add https://github.com/GreyforgeLabs/reprieve.git --enable --yes` on a machine with no prior Reprieve state |
| Automated matrix | `tests/live/acceptance.sh` — **33 passed, 0 failed** (full mode, two `omarchy restart shell` cycles) |

## Acceptance matrix

| # | Case | Result | How |
| --- | --- | --- | --- |
| 1 | Terminal (foot) park → restore | PASS | script: parked to `special:reprieve`, journaled, restored to original workspace, focused |
| 2 | Chromium park → restore with tabs intact | PASS | manual: throwaway profile with two tabs; same address, same pid, title intact after restore |
| 3 | Multiple windows parked in sequence | PASS | script |
| 4 | Undo out of timeline order | PASS | script: middle entry restored, others stay parked |
| 5 | Redo | PASS | script |
| 6 | Restore to original workspace | PASS | script |
| 7 | Restore to current workspace | PASS | script: switched workspace, `restoreAt {here:true}` lands there |
| 8 | Floating window | PASS | script: floating journaled and restored floating (after the `float enable/disable` fix) |
| 9 | Fullscreen window | PASS | script: `fullscreen=1/client=1` journaled, cleared while parked, restored exactly |
| 10 | Park with active media | PASS | script: PipeWire stream muted, record journaled, unmuted on restore; also verified resume after a shell restart |
| 11 | Permanent close | PASS | script: window destroyed, entry dropped, app not left muted in stream-restore |
| 12 | Stack overflow | PASS | manual: `maxStack=2` in shell.json, 3 recovered + 1 new park → oldest closed, journal and hidden workspace agree (2/2) |
| 13 | Plugin reload while two windows are parked | PASS | manual: touched `Panel.qml` → "Local plugin changed" reload; both entries kept, `restoreAll` returned both |
| 14 | `omarchy-shell` reload while windows are parked | PASS | script: both entries kept in order; undo after restart restores to original workspace |
| 15 | Reprieve update/reload while window is parked | PASS | manual: code synced into the plugin dir + shell restart with windows parked, several times during development; journal recovered them each time |
| 16 | Simulated damaged recovery state | PASS | script: corrupt JSON quarantined to `state.json.json.<ts>`, stranded windows exposed as Recovered and restorable |
| 17 | `reset` with parked windows | PASS | script: every parked window restored, nothing tracked afterwards; `clear` refused while parked |
| 18 | Conflicting existing keybind | PASS | offline tests (occupied `Super+Z` skipped / alternate / replace; custom `Super+W` refused without `--replace park`); live: `status` reports conflicts from `hyprctl -j binds` |
| 19 | Migration from a legacy desktop-undo block | PASS | manual: legacy block re-added and live, `installBinds` from the setup card removed it, wrote Reprieve's block, reloaded, verified live; `omarchy plugin disable io.github.greyforgelabs.desktop-undo` |
| 20 | Uninstall | PASS | manual: `reprieve uninstall` + `omarchy plugin remove` → block gone, `~/.local/bin/reprieve` gone, stock `Super+W = Close window` live again |
| S | Window moved to `special:reprieve` by hand | PASS | script: adopted as Recovered |
| P | Parked process dies | PASS | script (foot → entry removed); manual (chromium → converted to Reopen) |
| F | First-run setup | PASS | manual: card auto-opens after `plugin add --enable`; keyboard consent disarmed for 2.5 s; button path installs, `reprieve doctor` PASS |

Critical requirement — *no supported test may leave a live application
stranded on the special workspace without a recoverable path* — held in every
run; the matrix ends by asserting the hidden workspace is empty.

## Defects found and fixed during qualification

- Hyprland 0.56 `window.float` treats `action = "set"`/`"unset"` as toggle;
  restore flipped floating state. Fixed with `enable`/`disable`.
- Omarchy 4.0.3 gives third-party plugins no `shell.shellConfig`; settings
  silently defaulted. Fixed by reading `shell.json` from disk.
- Omarchy strips `__sourceDir` from third-party manifests, which left the media
  helper path empty. Fixed by resolving from `Qt.resolvedUrl`.
- PipeWire stream-restore remembered "muted" for apps closed while parked.
  Fixed by queueing Reprieve's own closes behind the unmute job.
- The auto-opened setup card could take a stray Enter as consent. Fixed by
  disarming keyboard consent for 2.5 s on auto-open (a click is always accepted).

## Known limitations

- If a parked app's process dies on its own while muted, PipeWire may remember
  it as muted; Reprieve cannot unmute a stream that no longer exists.
- Recovery after a *compositor* restart is out of scope: Hyprland itself
  closes all windows; the stale journal is quarantined, not replayed.
- Reopen covers only Chrome/Chromium/Brave/Firefox and Omarchy web apps.
- Windows that refuse to close on overflow (unsaved-changes prompts) are
  re-adopted as Recovered rather than force-killed; the next overflow will try
  again.
- Recovered entries have no recorded workspace and restore to the current one.
- No bar widget in 1.0 (evaluated; omitted to keep the implementation small).
