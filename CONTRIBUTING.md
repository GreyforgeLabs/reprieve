# Contributing

Reprieve is deliberately small. Before proposing a feature, answer:

> Does this materially improve prevention of, or recovery from, an accidental
> window close?

If not, it belongs somewhere else.

## Running tests

```sh
tests/run.sh
```

Needs `node` and `python3`. On Omarchy it also runs `omarchy plugin validate`.

## Layout

```text
manifest.json        Omarchy plugin manifest (service + overlay)
Service.qml          headless service: park/restore, journal, reconciliation, events
Panel.qml            timeline + setup overlay + toast
BarWidget.qml        bar widget (glyph, count, per-window icon tray)
BarIcons.js          class → app icon lookup for the tray
ReprieveModel.js     pure model; the only place that decides what happens
bin/reprieve         CLI and keybind wrapper
bin/reprieve-journal atomic state file helper
bin/reprieve-binds   bindings.lua marker-block editor
bin/reprieve-doctor  read-only diagnostics
bin/reprieve-media   PipeWire/MPRIS pause+resume helper
tests/               offline tests
```

## Rules

- Anything that reaches a Hyprland dispatch must pass `normalizeAddress` /
  `normalizeWorkspace` first.
- No shell strings. Subprocesses take argument lists.
- Never persist argv, environment, or titles.
- Prefer preserving a live window over cleaning up bookkeeping.
- Verify Hyprland Lua dispatcher arguments against the installed version;
  the stubs in `/usr/share/hypr/stubs/hl.meta.lua` and the Hyprland sources
  are authoritative, not old examples.
- Live changes need a run through the acceptance matrix in
  `docs/QUALIFICATION.md` on a real Omarchy session before release.

## Commits

Small, explained commits. Keep the LICENSE notice intact.
