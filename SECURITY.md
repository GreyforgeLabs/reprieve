# Security

## Trust model

Reprieve runs unprivileged inside `omarchy-shell` as the logged-in user. It
has no network access, no telemetry, and never asks for elevation.

Inputs it treats as untrusted:

- Hyprland window metadata (address, class, title, workspace, pid);
- the recovery journal on disk;
- `~/.config/hypr/bindings.lua`;
- output of `hyprctl`, `pactl`, `busctl`.

Guarantees it aims to keep:

- validated addresses and workspace names before any compositor dispatch;
- no shell interpolation (all subprocesses use argument vectors);
- no argv/environment/command persistence; relaunch is a fixed allowlist;
- atomic, symlink-refusing, size-bounded writes to state and config;
- malformed state is quarantined, never executed;
- media resume only for streams whose pid still matches, within the same
  compositor session.

## Reporting

Please report vulnerabilities privately by opening a GitHub security advisory
on https://github.com/GreyforgeLabs/reprieve (Security → Report a
vulnerability). Include Omarchy and Hyprland versions and, if possible, a
minimal reproduction. You should hear back within a week.
