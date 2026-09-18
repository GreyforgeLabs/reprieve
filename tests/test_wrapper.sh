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
# STUB_MODE: parked | passthrough | empty | slow | down
case "${STUB_MODE:-}" in
  parked)      echo "parked" ;;
  passthrough) echo "passthrough" ;;
  empty)       true ;;
  slow)        sleep 5 ;;
  down)        exit 1 ;;
  *)           echo "bad stub mode" >&2; exit 2 ;;
esac
EOF
cat > "$STUB/hyprctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$HYPRCTL_LOG"
EOF
chmod +x "$STUB/omarchy-shell" "$STUB/hyprctl"

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

echo "wrapper: passed $pass, failed $fail"
[[ $fail -eq 0 ]]
