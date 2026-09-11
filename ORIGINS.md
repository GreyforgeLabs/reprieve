# Origins

Reprieve is an independent, Greyforge-maintained project derived from
**GreyforgeLabs/omarchy-desktop-undo**.

| | |
| --- | --- |
| Original project | https://github.com/GreyforgeLabs/omarchy-desktop-undo ("Tile Park and Undo") |
| Original author | Greyforge Labs |
| Original license | MIT (see [LICENSE](LICENSE); the copyright notice is retained) |
| Audited source baseline | commit `15e4daca186c86093b10a2dfecc3dae70dfd9378` ("Harden media after sleep and drop leftover snapshot chmod."), upstream version 1.2.3 |
| Staging fork | https://github.com/GreyforgeLabs/omarchy-desktop-undo (archived once Reprieve became independently installable) |
| Reprieve repository | https://github.com/GreyforgeLabs/reprieve |
| Git history | Upstream history up to the baseline is preserved in this repository |

## What Reprieve keeps from the original

The core idea and its best property: an accidental `Super+W` **parks the live
window** on a hidden special workspace instead of destroying it, so the same
process and window come back on undo. Also kept in spirit or in code:

- the pure JS model + Quickshell service + overlay structure;
- the bounded park stack with overflow-close;
- the narrow relaunch allowlist through `omarchy-launch-browser` / `omarchy-launch-webapp`;
- the PipeWire/MPRIS media helper (`bin/reprieve-media`) and its tests;
- the "never bind Ctrl+Z" rule and the CLI fallback to a real close.

## Major architectural divergence

Greyforge did not write the original implementation. Greyforge did write:

- **Persistent recovery journal** (`~/.local/state/reprieve/state.json`),
  session-bound to `HYPRLAND_INSTANCE_SIGNATURE`, written atomically with
  `0700`/`0600` modes, symlink refusal and size bounds (`bin/reprieve-journal`).
- **Startup reconciliation** of journal + live toplevels + hidden workspace,
  including recovery of stranded windows and conversion of dead entries.
- **Safe reset semantics**: `restore-all`, a `clear` that refuses to orphan
  live windows, and a `reset` that restores before forgetting.
- **Exact state restoration**: floating/tiled and Hyprland `fullscreen_state`
  (internal + client) restored from recorded values; focus on restore.
  (This also fixed a latent upstream bug: Hyprland 0.56's `window.float`
  treats `action = "set"` as a toggle.)
- **Address-scoped event suppression** replacing the global timer guard.
- **Parked-process death handling** that converts to Reopen or removes.
- **Conflict-aware keybinding editor** (`bin/reprieve-binds`) with live
  `hyprctl binds` inspection, alternates, explicit replace, atomic writes,
  exact removal, and migration of legacy marker blocks.
- **First-run setup card**, revised timeline (Recovered/Parked/Reopen,
  Restore All, two-step permanent close, recovery notice).
- `reprieve` CLI, `reprieve doctor`, the journal/bind test suites, CI, docs.

## Namespaces

Old identifiers survive only where needed for migration detection and
attribution:

```text
io.github.greyforgelabs.desktop-undo   legacy marker block / plugin id (migration)
io.github.chris.desktop-undo      earlier experiment's marker block (cleanup)
```

Everything active is `tech.greyforge.reprieve`, `special:reprieve`,
`~/.local/state/reprieve/`, `reprieve`.
