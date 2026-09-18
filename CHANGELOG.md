# Changelog

All notable changes to Reprieve. Versions follow SemVer.

## [Unreleased]

### Fixed
- **Second Super+W no longer destroys the parked window.** After a park,
  Hyprland focus routinely lingers on the just-hidden window (with a single
  window on the workspace it never leaves), so a second Super+W targeted
  Reprieve's own hidden window. The service answered `passthrough` and the
  keybind wrapper turned that into a real close. Pressing Super+W on an
  already-parked window is now a no-op (`empty`); all flight modes affected.
- **Slow shell no longer turns Super+W into a close.** The wrapper
  distinguished only the response text, so an IPC answer arriving after the
  0.6 s `timeout` (empty output) fell through to a real Hyprland close.
  A timed-out park (`timeout` exit 124) now exits quietly and leaves the
  window alone; only an explicit refusal or a fast transport failure
  (shell truly down) still degrades to a close, as documented.
- New offline coverage: `tests/test_wrapper.sh` drives the real
  `bin/reprieve` against stubbed `omarchy-shell`/`hyprctl` (park, refusal,
  dead shell, empty output, forced timeout, close action) and runs as part
  of `tests/run.sh`.

## [1.4.0] – 2026-09-17

### Added
- **Flights.** Parking a window flies a snapshot of it into the Reprieve
  bar mark (which flares as it lands); restoring flies it back and the live
  window takes over on touchdown. New `flight` setting — `subtle` (default),
  `angel` (a winged light swoops down from the mark, lifts the window and
  carries it home; restoring is the same trip in reverse — she rises out
  of the mark with it, sets it down, and flies back) or `off` (the previous
  cut) — via `reprieve set flight …`, the timeline's **Flight** control
  (**F** / Shift+F) or the shell.json entry. `Flight.qml` draws on a
  per-screen overlay layer that is mapped only while a flight is in the
  air and never takes input. The service keeps ownership of the real
  move: the overlay calls back at the handover frame and a 1.4 s watchdog
  moves the window anyway if it never does. Restores landing on another
  workspace stay cuts; snapshots are not persisted across shell restarts.
- The bar widget publishes the mark's on-screen position per screen
  (`status` reports it under `flight.anchors`) so flights land on it;
  `flight.flown` counts completed flights.
- A restore to another workspace switches there first and then flies
  (the focus would have switched anyway); restores without focus that
  land elsewhere stay cuts.

### Changed
- The timeline's preference cards are a 2×2 grid, each with a one-line
  description (Toasts, Pause audio, Auto-close, Flight) instead of a
  single cramped row.

## [1.3.0] – 2026-09-16

### Changed
- The overlay, the toast and the bar widget carry the Greyforge Labs
  identity: the steel hexagon mark with cyan seams and a single amber core
  (`brand/GreyforgeMark.qml`, drawn on a Canvas so it follows the theme's
  foreground and background), a "GREYFORGE LABS" byline under the product
  name, a signature wordmark at the foot of every card, and a blueprint
  plate behind the timeline.
- Timeline rows show the application icon on a steel plate, a
  PARKED / RECOVERED / REOPEN chip, a cyan selection rail, and the timeout
  countdown in amber. Keyboard hints are rendered as keycaps instead of a
  run-on sentence.
- Restore All is an amber primary button above a preferences strip:
  Toasts (`T`), Pause audio on park (`M`), and the 1.2.0 park timeout as an
  **Auto-close** stepper (`P` / click / wheel for the next preset, Shift+P /
  right-click for the previous: Off, 15 s, 30 s, 1 min, 2 min). The strip
  writes through the service, so `reprieve set …` and the overlay agree; a
  CLI value off the preset list steps to the nearest preset. The
  setup card lays the five keybindings out as a keycap table and explains
  what parking means before asking for consent.
- The bar widget's status glyph is now the Greyforge mark: the amber core
  grows and the plate flares when a window is parked, the core takes the
  theme's alert colour when attention is needed, and the overflow count
  rides the corner as a badge. Tray icons sit on small cyan-edged plates
  with an amber (parked) or cyan (recovered) marker.
- The toast leads with the mark and an amber edge rail.
- Screenshots in `docs/screenshots/`.

## [1.2.0] – 2026-09-16

### Added
- Optional `parkTimeout` setting: auto-close parked windows not restored
  within N seconds. Off (`0`) by default; `5`–`120` when enabled
  (`reprieve set parkTimeout 30`, `0` to disable). The clock starts at park
  time, restoring cancels it, and entries parked before this setting
  existed are exempt until re-parked. Enabling the timeout grants parked
  windows a full interval from that moment; a shell restart with the
  timeout on grants the same fresh interval. Re-hiding a restored window
  restarts its clock. Journal schema is unchanged (v1):
  `parkedAt` is an optional field, so old and new versions read each
  other's journals without quarantine.
- Timeline rows show a per-window `closes in Ns` countdown while the
  timeout is active (exempt rows show none).
- `reprieve doctor` and `reprieve bar status` report the park timeout.
- `reprieve set` reports the effective value when a setting is clamped
  (`ok (using 5)`).
- Live acceptance matrix covers the timeout: expiry, enable-grace, and
  restore-cancels.

### Fixed
- A shell restart with the timeout on grants parked windows a fresh
  interval instead of expiring them on the spot for age accrued while the
  shell was down (same grace as enabling at runtime).
- The timeline restores the clicked row by address, so a timeout sweep
  landing between render and click can no longer restore the wrong window.
- `reprieve remove-binds` removes the `~/.local/bin/reprieve` link even
  when `bindings.lua` is already gone.
- Binding backups are pruned to the five most recent.
- A truncated `shell.json` read no longer resets all settings to defaults;
  the last good entry is kept until the file parses again.
- Quarantine filenames are PID-qualified so two quarantines within the
  same second no longer overwrite each other.
- The media helper answers `{"unmuted": 0, "played": 0}` instead of
  tracebacking on a malformed resume payload, and skips non-dict mute
  records and non-string player names.

### Removed
- `reprieve migrate` and the setup card's migration path for marker blocks
  written by earlier close-parking plugins. Reprieve now manages only its own
  `tech.greyforge.reprieve` block.

## [1.1.2] — 2026-09-14

### Fixed
- MPRIS player matching no longer pauses the wrong player. A PID substring
  (e.g. pid 86 inside `instance5868`) could match an unrelated bus name;
  PIDs must now match as whole numbers.

## [1.1.1] — 2026-09-13

### Fixed
- Parking no longer changes persistent application mute. A disappearing or
  replaced stream could leave browser audio muted even after restore or an
  application restart. Existing journal records still clean up matching live
  streams; already-orphaned mutes require application-level unmute once.
- Disabling media pausing no longer skips recorded cleanup before closing a
  parked window. Failed media commands are no longer counted as successful.

### Changed
- Media pausing uses MPRIS only. Players without pause support can keep
  playing while parked; mixer mute and volume remain under user control.

## [1.1.0] — 2026-09-11

### Added
- Bar widget (`kinds: bar-widget`, placed in the right section on install):
  glyph with `+N` overflow, per-window app icons that restore on click
  (right-click restores here), alert color + tooltip when setup, unloaded
  bindings, or a stranded window needs attention; pulses on park; hides when
  idle.
- Settings `showInBar`, `barTray`, `barMaxIcons`, `hideBarWhenIdle`; `reprieve
  set KEY VALUE`; `reprieve bar status|install|show|tray|hide-idle|icons`.
- `strandedCount`, `attention`, `restoreAddress` and `windowParked` on the
  service; `settings`/`setSetting`/`restoreAddress` IPC.

### Changed
- Settings are read from wherever Omarchy keeps the plugin's entry (bar layout
  or `plugins[]`). Existing installs move the entry with `reprieve bar install`.

## [1.0.0] — 2026-09-11

First release.

### Added
- Persistent, session-bound recovery journal with atomic writes, quarantine of
  malformed state, and startup reconciliation against live Hyprland windows.
- Recovery of stranded windows on `special:reprieve` as **Recovered** entries;
  adoption of windows moved there by anything other than Reprieve.
- `restore-all`, `clear` (refuses while windows are parked), and a `reset`
  that restores before forgetting.
- Exact floating and fullscreen (`internal` + `client`) restoration; focus on restore.
- Conversion of a dead parked window into a **Reopen** entry when allowlisted.
- Address-scoped expected-event tracking for Reprieve's own moves and closes.
- Conflict-aware keybinding install with live-bind inspection, alternate
  combinations, explicit replace, atomic backup+rename writes, and exact
  removal.
- First-run setup card with delayed keyboard arming; timeline Restore All,
  two-step permanent close, recovery notice.
- `reprieve` CLI, `reprieve doctor`, `~/.local/bin/reprieve` link on setup.
- Offline tests for model, journal, bindings, media; GitHub Actions CI.

### Changed
- Product identity: `tech.greyforge.reprieve`, `special:reprieve`,
  `~/.local/state/reprieve/`. Settings live in `shell.json` and are read from
  disk (the third-party shell API exposes none).
- Plugin directory resolved without `__sourceDir` (stripped by Omarchy 4 for
  third-party plugins), which had left the media helper unreachable.

### Fixed
- Restored windows no longer flip floating state: Hyprland's `window.float`
  treats `action = "set"`/`"unset"` as toggle; Reprieve uses `enable`/`disable`.
- Journal-free reloads no longer lose parked windows.
