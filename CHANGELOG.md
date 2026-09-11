# Changelog

All notable changes to Reprieve. Versions follow SemVer.

## [Unreleased]

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
  combinations, explicit replace, atomic backup+rename writes, exact removal,
  and migration of legacy `desktop-undo` marker blocks.
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
