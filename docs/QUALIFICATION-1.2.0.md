# Reprieve 1.2.0 qualification

Release base: `main` at 1.2.0 (includes `parkTimeout`, timeline countdown,
doctor/bar surfacing, audit fixes). Offline suite green on greyarch
(node 26 / python 3.14): 36 model, 10 journal, 18 binding, 8 media tests;
`py_compile`, `bash -n`, `check_namespace.sh`, `omarchy plugin validate` clean.

## Live matrix — PASS 40/40, 0 failures

Run 2026-09-16 on greyarch (Omarchy 4 / Hyprland 0.56 session
`efb5099…`, deployed via `.sync.sh` + shell restart): full
`tests/live/acceptance.sh`, including the new block 20:

- 20 timeout value reported in status — PASS
- 20 parked window auto-closes after the timeout — PASS
- 20 enabling grants a full timeout from enable time — PASS
- 20 window expires once the post-enable interval elapses — PASS
- 20 restoring before the deadline cancels the timeout — PASS

Pre-existing cases 1–19, S, P, B, Z all PASS unmodified; nothing left on
`special:reprieve` at the end. No test stranded a live application.

Deploy note: `keepLoaded` services intentionally survive file-change
hot-reloads (shell keeps the instance by design), so a plugin code update
needs a full shell restart to take effect — verified during this release.

## Still pending (manual, not run)

| # | Case | How |
| --- | --- | --- |
| T | Timeline shows per-row "closes in Ns" countdown | eyeball: enable timeout, open timeline, watch a row count down |
| T | Countdown hidden when timeout off / exempt rows | eyeball: `parkTimeout 0`, no countdown text on any row |
| R | Restart with timeout on grants a fresh interval, no mass-close | park, enable timeout, restart shell, window still parked with full countdown |
