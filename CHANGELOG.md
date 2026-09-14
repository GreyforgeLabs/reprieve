# Changelog

All notable changes to Reprieve. Versions follow SemVer.

## [Unreleased]

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
