#!/usr/bin/env bash
# Offline tests for bin/reprieve park/close fallback branching.
# Stubs omarchy-shell + hyprctl on PATH; the real `timeout` is used so the
# slow-shell case exercises a genuine timeout (exit 124).
set -euo pipefail
cd "$(dirname "$0")/.."

STUB=$(mktemp -d)
LOG="$STUB/hyprctl.log"
trap 'rm -rf "$STUB"' EXIT

cat > "$STUB/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
# STUB_MODE: parked | passthrough | empty | noactive | slow | down | placed
case "${STUB_MODE:-}" in
  placed)      case "$2" in
                 status)   echo '{"entry":"bar","parked":0,"bar":{"placed":true}}' ;;
                 settings) echo '{}' ;;
               esac ;;
  parked)      echo "parked" ;;
  passthrough) echo "passthrough" ;;
  empty)       true ;;
  noactive)    echo "empty" ;;
  slow)        sleep 5 ;;
  down)        exit 1 ;;
  *)           echo "bad stub mode" >&2; exit 2 ;;
esac
EOF
cat > "$STUB/hyprctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$HYPRCTL_LOG"
EOF
cat > "$STUB/omarchy" <<'EOF'
#!/usr/bin/env bash
echo "omarchy $*" >> "$HYPRCTL_LOG"
EOF
chmod +x "$STUB/omarchy-shell" "$STUB/hyprctl" "$STUB/omarchy"

pass=0; fail=0
check() { # name, expected_hyprctl_calls, then command...
  local name="$1" want_calls="$2"; shift 2
  : > "$LOG"
  set +e
  PATH="$STUB:$PATH" HYPRCTL_LOG="$LOG" STUB_MODE="$STUB_MODE" bash bin/reprieve "$@"
  local rc=$?
  set -e
  local got_calls=0
  [[ -s "$LOG" ]] && got_calls=$(wc -l < "$LOG")
  if [[ $rc -eq 0 && "$got_calls" == "$want_calls" ]]; then
    pass=$((pass+1)); echo "PASS  $name"
  else
    fail=$((fail+1)); echo "FAIL  $name (rc=$rc hyprctl_calls=$got_calls want=$want_calls)"
  fi
}

STUB_MODE=parked;      check "parked parks without touching hyprctl" 0 park
STUB_MODE=passthrough; check "explicit refusal still degrades to close" 1 park
STUB_MODE=down;        check "dead shell still degrades to close" 1 park
STUB_MODE=empty;       check "empty success output degrades to close" 1 park
STUB_MODE=slow;        check "timed-out park never closes (the safety net holds)" 0 park
STUB_MODE=down;        check "close action still closes when shell is down" 1 close
STUB_MODE=noactive;    check "close falls back when plugin has no active toplevel" 1 close

# Helper commands still find their siblings through the ~/.local/bin link.
ln -s "$PWD/bin/reprieve" "$STUB/reprieve"
if (cd / && PATH="$STUB:$PATH" reprieve binds --help 2>/dev/null | grep -q "usage: reprieve-binds"); then
  pass=$((pass+1)); echo "PASS  helper commands resolve the plugin directory through a symlink"
else
  fail=$((fail+1)); echo "FAIL  helper commands resolve the plugin directory through a symlink"
fi

# Super+W launches nothing but the IPC call (no path resolution helpers).
for tool in readlink dirname; do
  printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$tool" "$LOG" "$(command -v $tool)" > "$STUB/$tool"
  chmod +x "$STUB/$tool"
done
: > "$LOG"
PATH="$STUB:$PATH" HYPRCTL_LOG="$LOG" STUB_MODE=parked bash bin/reprieve park
if [[ ! -s "$LOG" ]]; then
  pass=$((pass+1)); echo "PASS  park spawns no path-resolution helpers"
else
  fail=$((fail+1)); echo "FAIL  park spawns no path-resolution helpers ($(tr '\n' ' ' < "$LOG"))"
fi

# `bar` subcommands: a stopped shell is reported, not a Python traceback.
set +e
err=$(PATH="$STUB:$PATH" HYPRCTL_LOG="$LOG" STUB_MODE=down bash bin/reprieve bar status 2>&1 >/dev/null); rc=$?
set -e
if [[ $rc -eq 1 && "$err" == *"plugin is not running"* && "$err" != *Traceback* ]]; then
  pass=$((pass+1)); echo "PASS  bar status with the shell down reports it without a traceback"
else
  fail=$((fail+1)); echo "FAIL  bar status with the shell down reports it without a traceback (rc=$rc)"
fi

# An already placed widget stays where it is unless a section is named.
: > "$LOG"
out=$(PATH="$STUB:$PATH" HYPRCTL_LOG="$LOG" STUB_MODE=placed bash bin/reprieve bar install)
if [[ ! -s "$LOG" && "$out" == *"already placed"* ]]; then
  pass=$((pass+1)); echo "PASS  bar install without a section keeps a placed widget where it is"
else
  fail=$((fail+1)); echo "FAIL  bar install without a section keeps a placed widget where it is ($(tr '\n' ' ' < "$LOG")/ $out)"
fi
: > "$LOG"
out=$(PATH="$STUB:$PATH" HYPRCTL_LOG="$LOG" STUB_MODE=placed bash bin/reprieve bar install center)
if [[ "$(cat "$LOG")" == "omarchy plugin enable tech.greyforge.reprieve --section center" && "$out" == *"center section"* ]]; then
  pass=$((pass+1)); echo "PASS  bar install SECTION moves a placed widget and says so"
else
  fail=$((fail+1)); echo "FAIL  bar install SECTION moves a placed widget and says so ($(tr '\n' ' ' < "$LOG")/ $out)"
fi

echo "wrapper: passed $pass, failed $fail"
[[ $fail -eq 0 ]]
