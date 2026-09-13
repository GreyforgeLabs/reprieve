# Reprieve

Reliable window-close recovery for [Omarchy](https://omarchy.org/).

> Hit Super+W by accident? Reprieve parks the window instead of killing it.
> Super+Z brings it back exactly as it was.

Stock Omarchy closes the focused window on `Super+W`. Reprieve turns that
into a reversible **park**: the live application window is moved to a hidden
workspace, not destroyed. Your browser tabs, your terminal session, your
unsaved buffer are all still there — the same process, the same window.

Reprieve is small on purpose. It is not a desktop time machine. It does one
thing: it makes an accidental close recoverable, and it keeps that promise
across shell reloads, plugin updates, and its own bookkeeping mistakes.

## What Reprieve does

| You press        | Reprieve does                                              |
| ---------------- | ---------------------------------------------------------- |
| `Super+W`        | Parks the focused window on `special:reprieve`             |
| `Super+Z`        | Restores the most recently parked window, where it was     |
| `Super+Y`        | Parks it again (redo)                                      |
| `Super+Shift+Z`  | Opens the recovery timeline                                |
| `Super+Alt+W`    | Closes the focused window for real                         |

Two words matter throughout:

```text
Restore = the same live window comes back (workspace, floating, fullscreen)
Reopen  = a safe best-effort relaunch of an app whose window is gone
```

Reopen exists only for a short allowlist (Chrome/Chromium, Brave, Firefox,
Omarchy web apps) and only ever runs `omarchy-launch-browser` or
`omarchy-launch-webapp https://<host>`. Reprieve never records or replays
command lines.

## Install

```sh
omarchy plugin add https://github.com/GreyforgeLabs/reprieve.git --enable
```

Requires Omarchy 4 on Hyprland 0.56+ with Python 3 (stdlib only), `hyprctl`,
`pactl`, and `busctl` — all present on a stock install.

Enabling the plugin changes nothing about your keybindings.

## First-run setup

When Reprieve loads without its keybindings it opens a compact setup card:

```text
Reprieve

Protect Super+W from accidental closes?

[ Enable Protection ]

Super+W       Park window
Super+Alt+W   Close permanently
Super+Z       Restore
```

Nothing is written until you press **Enable Protection** (a click, or Enter
once the card has been visible for a moment). Reprieve then:

1. backs up `~/.config/hypr/bindings.lua`;
2. appends one marked block between `-- BEGIN tech.greyforge.reprieve` and
   `-- END tech.greyforge.reprieve`, written atomically;
3. reloads Hyprland and verifies the bindings are live;
4. links `~/.local/bin/reprieve` to its CLI (never over a file it did not create).

`Super+W` replaces Omarchy's stock close binding — that is the product. The
other shortcuts are conflict-aware: if `Super+Z`, `Super+Y`, or
`Super+Shift+Z` is already bound to something of yours, the card says so and
offers an alternate combination (`A`), an explicit replace (`R`), or
installation without that shortcut (Enter). A custom `Super+W` is never taken
over without you choosing **R**.

You can reopen the card at any time:

```sh
~/.config/omarchy/plugins/tech.greyforge.reprieve/bin/reprieve setup
# or, after setup:
reprieve setup
```

Press `L` on the card to be left alone; it will not reappear.

## Shortcuts

Defaults, all editable through setup:

| Shortcut         | Action                        |
| ---------------- | ----------------------------- |
| `Super+W`        | Park window                   |
| `Super+Alt+W`    | Close window permanently      |
| `Super+Z`        | Restore parked window         |
| `Super+Y`        | Redo park                     |
| `Super+Shift+Z`  | Reprieve timeline             |

Applications keep ordinary `Ctrl+Z`; Reprieve never binds it.

## Recovery timeline

`Super+Shift+Z` lists everything Reprieve can bring back, newest first:

- **Parked** — a live window on the hidden workspace.
- **Recovered** — a live window Reprieve found on the hidden workspace after a
  reload without a record of where it came from. Restoring it lands it on
  your current workspace.
- **Reopen** — the window is gone but the app is on the relaunch allowlist.

Keys: **Enter** restores to the original workspace, **Space** restores to the
workspace you are on, **A** restores everything, **Y** redoes the last park,
**Del** (twice, on the same row) closes a parked window permanently, **T**
toggles the top-right toast, **Esc** closes.

Restore puts the window back tiled or floating as it was, re-applies the exact
fullscreen state it had, focuses it, and resumes media Reprieve paused.

## Bar widget

Super+W is minimize, so the bar shows where the window went. Reprieve's bar
widget (placed automatically on install) has three parts:

- a glyph that turns to the theme's alert color while something needs you
  (not set up yet, a legacy block still present, bindings not loaded, or a
  hidden window with no timeline entry) — click it and it takes you there;
- one **app icon per parked window**, newest first: click restores that
  window where it was, right-click restores it to the current workspace;
- a `+N` count when more windows are parked than icons shown.

Left-click the glyph for the timeline, right-click to restore the last parked
window, middle-click to restore everything. The widget pulses briefly when a
window is parked and hides itself when nothing is parked.

```sh
reprieve bar status              # where it is, what is on
reprieve bar tray off            # count only, no per-window icons
reprieve bar hide-idle off       # keep the glyph visible when idle
reprieve bar icons 8             # icons before collapsing into +N (1–10)
reprieve bar show off            # no bar presence at all (service keeps running)
reprieve bar install left        # place it (or move it) — see below
```

Drag it along the bar like any other widget, or `omarchy bar move
tech.greyforge.reprieve --section center`.

Upgrading from 1.0? Omarchy keeps a bar widget's config entry in the bar
layout, and 1.0 installs have theirs in `plugins[]`. `reprieve bar install`
moves it using Omarchy's own enable/disable (the service restarts for a
second; the recovery journal carries parked windows across) and re-applies
your settings.

## Crash and reload recovery

Reprieve keeps a small recovery journal at
`~/.local/state/reprieve/state.json` (directory `0700`, file `0600`). It holds
only what is needed to find parked windows again: address, original
workspace, class, floating/fullscreen flags, pid, order, and — when audio was
paused — which MPRIS players to resume, plus legacy mixer cleanup records. No titles, no
command lines, no environment.

The journal is bound to the current Hyprland session. On start Reprieve
reconciles three sources — the journal, the compositor's live window list,
and whatever is actually sitting on `special:reprieve` — and:

- restores journaled parked windows to the timeline in their original order;
- exposes any stranded window on the hidden workspace as **Recovered**;
- turns a journal entry whose window has died into a **Reopen** when the app is
  allowlisted, and otherwise discards it;
- quarantines a malformed or foreign-session journal (`state.json.<reason>.<time>`)
  and rebuilds from live windows.

If a parked window's process dies later, the entry becomes a Reopen or is
removed with a short toast. Nothing is ever left hidden without a way back.

## CLI

```text
reprieve status        JSON: undo/redo counts, parked addresses, journal state
reprieve park          Park the focused window (what Super+W runs)
reprieve close         Close the focused window permanently
reprieve undo          Restore the most recently parked window
reprieve redo          Park it again
reprieve timeline      Open the timeline
reprieve restore-all   Bring every parked window back
reprieve clear         Forget history — refuses while windows are parked
reprieve reset         Restore every parked window, then forget history
reprieve setup         Open the setup card (installs bindings after consent)
reprieve migrate       Same card, for legacy desktop-undo installs
reprieve install-binds Non-interactive install (--undo/--redo/--timeline KEY,
                       --skip a,b, --replace a,b)
reprieve remove-binds  Remove Reprieve's marked block, nothing else
reprieve uninstall     Restore parked windows, remove bindings
reprieve bar ...       Bar widget: status, install, show/tray/hide-idle on|off, icons N
reprieve set KEY VALUE Change a setting
reprieve doctor        Read-only health check
```

`park` and `close` fall back to a real Hyprland close when the shell is not
answering, so `Super+W` never becomes a no-op while `omarchy-shell` restarts.

`reprieve doctor` never modifies anything:

```text
Reprieve Doctor

Hyprland         OK
Session          efb50993780079460b0cbe…
Plugin           OK
Journal          OK
Parked windows   2
Stranded         0
Bindings         OK
Conflicts        none
Media helper     OK

PASS
```

## Settings

On Reprieve's entry in `~/.config/omarchy/shell.json` (in the bar layout once
the widget is placed, otherwise in `plugins[]`) — or with `reprieve set KEY VALUE`:

| Key                | Default | What it does                                              |
| ------------------ | ------- | --------------------------------------------------------- |
| `maxStack`         | `10`    | Parked-window cap, 1–20. Overflow closes the oldest.      |
| `pauseMediaOnPark` | `true`  | Pause supported MPRIS players while hidden; audio without pause support keeps playing. |
| `trackAppClose`    | `true`  | Record title-bar closes of allowlisted apps as Reopen entries. |
| `showToast`        | `true`  | Top-right park/restore toast. Also toggled with **T**.    |
| `showInBar`        | `true`  | Show the bar widget at all.                               |
| `barTray`          | `true`  | Per-window app icons in the bar (off = glyph + count).    |
| `barMaxIcons`      | `5`     | Icons shown before collapsing into `+N`, 1–10.            |
| `hideBarWhenIdle`  | `true`  | Hide the widget when nothing is parked and nothing needs attention. |

```json
{ "id": "tech.greyforge.reprieve", "maxStack": 10, "pauseMediaOnPark": true, "barTray": true }
```

Parking uses media-player pause controls without changing application mute or
volume. Players without MPRIS pause support may keep playing while hidden.
Browsers can share a player across windows, so pausing one window may also
pause another window's playback.

Versions 1.0.0 and 1.1.0 could leave a saved application mute when a parked
audio stream disappeared or was replaced. Version 1.1.1 prevents new parking
mutes. For an existing mute, start playback and unmute the affected application
in the Audio widget once. See [the audio incident record](docs/AUDIO-MUTE.md).

The overlay follows the current Omarchy theme; there are no color settings.

## Migrating from an earlier close-parking plugin

If `bindings.lua` still carries a legacy `desktop-undo` marker block, the setup
card reads **Migrate to Reprieve**. Migration backs up the file, removes only
the recognised legacy block(s), writes Reprieve's block atomically, reloads
Hyprland and verifies. Then disable the old plugin so two parkers never share
`Super+W`:

```sh
omarchy plugin disable io.github.greyforgelabs.desktop-undo
```

`reprieve doctor` reports a still-enabled legacy plugin.

## Security and privacy

- No elevated privileges, no `sudo`, no network, no telemetry.
- Window address, class, title, workspace and pid are treated as untrusted:
  addresses and workspace names are validated before they reach a Hyprland
  dispatch; labels are stripped of control characters and rendered as plain text.
- No argv, environment, or command persistence. Reopen is a fixed allowlist.
- State and config writes are atomic (temp file + rename), refuse symlinks and
  non-regular files, and are size-bounded. Malformed state is quarantined,
  never executed.
- Media control runs a stdlib-only helper with a 2 s hard deadline and only
  touches streams whose pid matches the parked window.

See [SECURITY.md](SECURITY.md) for reporting.

## Troubleshooting

- **`Super+W` still kills windows** — run `reprieve doctor`. If bindings are
  "installed, not live", run `hyprctl reload`. If they are not installed, run
  `reprieve setup`.
- **A window vanished and is not in the timeline** — `reprieve doctor` reports
  `Stranded`; `reprieve restore-all` brings back everything on the hidden
  workspace, tracked or not.
- **`reprieve clear` refuses** — that is deliberate: it will not forget live
  parked windows. Use `reprieve restore-all` or `reprieve reset`.
- **Audio stayed muted after an older release** — start playback and unmute
  the application in the Audio widget once. Version 1.1.1 prevents new parking
  mutes; it does not clear orphaned mutes that were already saved.
- **Setup says a key is in use** — pick the alternate with `A`, replace with
  `R`, or install without it (Enter). `omarchy menu keybindings --print` shows
  who owns what.

## Remove

```sh
reprieve uninstall            # restores parked windows, removes the marked block
omarchy plugin remove tech.greyforge.reprieve
rm -rf ~/.local/state/reprieve
```

`uninstall` removes exactly Reprieve's block from `bindings.lua`, so `Super+W`
returns to Omarchy's stock close.

## License

MIT. See [LICENSE](LICENSE).
