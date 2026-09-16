#!/usr/bin/env bash
# Live acceptance matrix for Reprieve. Runs on a real Omarchy/Hyprland
# session with the plugin enabled. It spawns its own foot windows, drives the
# plugin over IPC (no synthetic keypresses), and restarts omarchy-shell twice.
#
# It never touches windows it did not create, except that "restore here"
# briefly switches to another workspace and back.
#
#   tests/live/acceptance.sh            run everything
#   tests/live/acceptance.sh --quick    skip the shell restarts
set -u

R="tech.greyforge.reprieve"
PARK="special:reprieve"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/reprieve/state.json"
QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1
pass=0; fail=0; results=()
SILENCE=""

ipc() { timeout 3 omarchy-shell "$R" "$@" 2>/dev/null; }
clients() { hyprctl -j clients; }
ws_of() { clients | python3 -c "import json,sys; print(next((c['workspace']['name'] for c in json.load(sys.stdin) if c['address']=='$1'),''))"; }
prop_of() { clients | python3 -c "import json,sys; print(next((c['$2'] for c in json.load(sys.stdin) if c['address']=='$1'),''))"; }
alive() { [[ -n "$(ws_of "$1")" ]]; }
status_field() { ipc status | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }
current_ws() { hyprctl -j activeworkspace | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])'; }
disp() { hyprctl dispatch "$1" >/dev/null 2>&1; }

# spawn() runs in command substitutions, so track our windows in a file.
MINE_FILE=$(mktemp)
spawn() {
  local before after
  before=$(clients | python3 -c 'import json,sys; print(" ".join(c["address"] for c in json.load(sys.stdin)))')
  setsid -f foot --title "reprieve-acceptance" "$@" >/dev/null 2>&1
  for _ in $(seq 1 40); do
    sleep 0.1
    after=$(clients | python3 -c "import json,sys; b=set('$before'.split()); print(next((c['address'] for c in json.load(sys.stdin) if c['address'] not in b and c['class']=='foot'),''))")
    [[ -n "$after" ]] && break
  done
  echo "$after" >> "$MINE_FILE"
  echo "$after"
}

check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then pass=$((pass+1)); results+=("PASS  $name"); echo "PASS  $name"
  else fail=$((fail+1)); results+=("FAIL  $name"); echo "FAIL  $name"; fi
}
eq() { [[ "$1" == "$2" ]]; }
wait_status() {
  for _ in $(seq 1 50); do
    [[ "$(status_field "$1" 2>/dev/null)" == "$2" ]] && return 0
    sleep 0.2
  done
  return 1
}

cleanup() {
  while read -r a; do
    if [[ -n "$a" ]] && alive "$a"; then
      ipc restoreAddress "$a" >/dev/null
      disp "hl.dsp.window.close({ window = \"address:$a\" })"
    fi
  done < "$MINE_FILE"
  rm -f "$MINE_FILE"
  [[ -n "${CLIENT:-}" ]] && pkill -f -- "client-name=$CLIENT" 2>/dev/null
  [[ -n "$SILENCE" ]] && rm -f "$SILENCE"
}
trap cleanup EXIT

echo "Reprieve live acceptance — $(date -Iseconds)"
echo "Omarchy $(cat /usr/share/omarchy/version 2>/dev/null) · $(hyprctl version | head -1 | cut -d' ' -f1-2) · plugin $(cd "$(dirname "$0")/../.." && git rev-parse --short HEAD 2>/dev/null)"
echo

[[ -n "$(ipc status)" ]] || { echo "plugin not running"; exit 1; }
[[ "$(status_field parked)" == "0" ]] || { echo "Refusing: user windows are parked"; exit 1; }
clients | python3 -c 'import json,sys; sys.exit(any(c["workspace"]["name"] == "special:reprieve" for c in json.load(sys.stdin)))' || { echo "Refusing: hidden workspace is occupied"; exit 1; }
home_ws=$(current_ws)
ipc restoreAll >/dev/null; ipc clear >/dev/null

# 1. terminal park -> restore
A=$(spawn)
ipc parkWindow "$A" >/dev/null; sleep 0.4
check "1 park moves window to $PARK"            eq "$(ws_of "$A")" "$PARK"
check "1 journal holds the entry"               grep -q "\"address\":\"$A\"" "$STATE"
check "1 restored window is focused" python3 "$(dirname "$0")/restore_focus.py" "$A"
sleep 0.5
check "1 undo restores to original workspace"   eq "$(ws_of "$A")" "$home_ws"

# 3/4/5/6. multiple windows, out-of-order undo, redo
B=$(spawn); C=$(spawn)
ipc parkWindow "$A" >/dev/null; sleep 0.2; ipc parkWindow "$B" >/dev/null; sleep 0.2; ipc parkWindow "$C" >/dev/null; sleep 0.4
check "3 three windows parked in sequence"      eq "$(status_field parked)" "3"
ipc restoreAt '{"index":1,"here":false}' >/dev/null; sleep 0.5
check "4 out-of-order restore brings back the middle one" eq "$(ws_of "$B")" "$home_ws"
check "4 others stay parked"                    eq "$(ws_of "$A")|$(ws_of "$C")" "$PARK|$PARK"
ipc redo >/dev/null; sleep 0.5
check "5 redo re-parks it"                      eq "$(ws_of "$B")" "$PARK"
ipc undo >/dev/null; sleep 0.5
check "6 undo restores newest (redo'd) to original workspace" eq "$(ws_of "$B")" "$home_ws"

# 7. restore here
other_ws=$(( ${home_ws//[!0-9]/} % 9 + 1 )); [[ "$other_ws" == "$home_ws" ]] && other_ws=$(( other_ws % 9 + 1 ))
disp "hl.dsp.focus({ workspace = \"$other_ws\" })"; sleep 0.3
ipc restoreAt '{"index":0,"here":true}' >/dev/null; sleep 0.5
check "7 restore here lands on the current workspace" eq "$(ws_of "$A")" "$other_ws"
disp "hl.dsp.window.move({ window = \"address:$A\", workspace = \"$home_ws\", follow = false })"
disp "hl.dsp.focus({ workspace = \"$home_ws\" })"; sleep 0.3
ipc restoreAll >/dev/null; sleep 0.4

# 8. floating
disp "hl.dsp.window.float({ window = \"address:$B\", action = \"enable\" })"; sleep 0.4
ipc parkWindow "$B" >/dev/null; sleep 0.4
check "8 floating flag journaled"               grep -q "\"address\":\"$B\",\"workspace\":\"[^\"]*\",\"class\":\"foot\",\"floating\":true" "$STATE"
ipc undo >/dev/null; sleep 0.5
check "8 floating window restored floating"     eq "$(prop_of "$B" floating)" "True"
disp "hl.dsp.window.float({ window = \"address:$B\", action = \"disable\" })"; sleep 0.3

# 9. fullscreen
disp "hl.dsp.window.fullscreen_state({ window = \"address:$C\", internal = 1, client = 1, action = \"set\" })"; sleep 0.5
ipc parkWindow "$C" >/dev/null; sleep 0.4
check "9 fullscreen state journaled"            grep -q "\"address\":\"$C\".*\"fullscreen\":1,\"fullscreenClient\":1" "$STATE"
check "9 parked window is not fullscreen"       eq "$(prop_of "$C" fullscreen)" "0"
ipc undo >/dev/null; sleep 0.6
check "9 fullscreen restored exactly"           eq "$(prop_of "$C" fullscreen)/$(prop_of "$C" fullscreenClient)" "1/1"
disp "hl.dsp.window.fullscreen_state({ window = \"address:$C\", internal = 0, client = 0, action = \"set\" })"; sleep 0.3

# 10. media
SILENCE=$(mktemp --suffix=.wav)
python3 - "$SILENCE" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], "w"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
w.writeframes(b"\x00\x00" * 8000 * 120); w.close()
PY
# A unique client name keeps PipeWire's per-app stream-restore out of the test.
CLIENT="reprieve-acceptance-$$"
M=$(spawn -e paplay --volume=0 --client-name="$CLIENT" "$SILENCE"); sleep 1.5
sink=$(pactl list sink-inputs | grep -B30 "application.name = \"$CLIENT\"" | grep -oE 'Sink Input #[0-9]+' | tail -1 | tr -dc 0-9)
mute_of() { pactl list sink-inputs | awk -v s="Sink Input #$1" '$0==s{f=1} f&&/Mute:/{print $2; exit}'; }
if [[ -n "$sink" ]]; then
  ipc parkWindow "$M" >/dev/null; sleep 1.5
  check "10 parking preserves the stream's mute" eq "$(mute_of "$sink")" "no"
  check "10 no mixer mute is journaled" python3 -c 'import json,sys; e=next(e for e in json.load(open(sys.argv[1]))["entries"] if e["address"]==sys.argv[2]); sys.exit(bool((e.get("media") or {}).get("muted")))' "$STATE" "$M"
  ipc undo >/dev/null; sleep 1.5
  check "10 restore preserves the stream's mute" eq "$(mute_of "$sink")" "no"
else
  echo "SKIP  10 media (no PipeWire sink input appeared)"
fi

# 11. permanent close from the timeline (of a window with active audio)
ipc parkWindow "$M" >/dev/null; sleep 1.5
ipc closeParked "$M" >/dev/null; sleep 1.0
check "11 permanent close destroys the window"  eq "$(ws_of "$M")" ""
check "11 and drops the entry"                  eq "$(status_field parked)" "0"
M2=$(spawn -e paplay --volume=0 --client-name="$CLIENT" "$SILENCE"); sleep 1.5
sink2=$(pactl list sink-inputs | grep -B30 "application.name = \"$CLIENT\"" | grep -oE 'Sink Input #[0-9]+' | tail -1 | tr -dc 0-9)
[[ -n "$sink2" ]] && check "11 app is not left muted in stream-restore" eq "$(mute_of "$sink2")" "no"
pkill -f -- "client-name=$CLIENT" 2>/dev/null; sleep 0.5

# 16. damaged state + stranded recovery, 13/14/15 shell restart
if [[ $QUICK -eq 0 ]]; then
  ipc parkWindow "$A" >/dev/null; sleep 0.2; ipc parkWindow "$B" >/dev/null; sleep 0.6
  omarchy restart shell >/dev/null 2>&1; sleep 5
  check "14 shell restart keeps both parked entries"   wait_status parked 2
  check "14 order preserved (newest is B)"             eq "$(status_field addresses | python3 -c 'import sys,ast; print(ast.literal_eval(sys.stdin.read())[-1])')" "$B"
  ipc undo >/dev/null; sleep 0.5
  check "14 undo after restart restores B to its workspace" eq "$(ws_of "$B")" "$home_ws"

  # Wait for the preceding restore's debounced journal write before replacing
  # the file, otherwise the test corruption can be overwritten before restart.
  wait_status parked 1
  sleep 1.5
  quarantine_before=$(python3 -c 'import glob,json,sys; print(json.dumps(glob.glob(sys.argv[1]+".*.*")))' "$STATE")
  echo '{"schema":1,"session":"nope","entries":[{"address":"0x1"}' > "$STATE"
  omarchy restart shell >/dev/null 2>&1; sleep 5
  wait_status recovered 1
  check "16 damaged journal is quarantined" python3 -c 'import glob,json,sys; sys.exit(not (set(glob.glob(sys.argv[1]+".*.*"))-set(json.loads(sys.argv[2]))))' "$STATE" "$quarantine_before"
  check "16 stranded window recovered"            eq "$(status_field recovered)" "1"
  ipc undo >/dev/null; sleep 0.5
check "16 recovered window restorable"          eq "$(ws_of "$A")" "$(current_ws)"
  # Preserve quarantine files, including any user recovery records from before this run.
else
  echo "SKIP  13/14/15/16 (quick mode)"
fi

# 17. reset with parked windows; clear refusal
ipc parkWindow "$A" >/dev/null; sleep 0.2; ipc parkWindow "$C" >/dev/null; sleep 0.4
clear_out=$(ipc clear)
check "17 clear refuses while windows are parked" bash -c "grep -q remain <<<'$clear_out'"
ipc reset >/dev/null; sleep 0.6
check "17 reset restores every parked window"   eq "$(ws_of "$A")|$(ws_of "$C")" "$home_ws|$home_ws"
check "17 reset leaves nothing tracked"         eq "$(status_field undo)$(status_field redo)" "00"

# 12. stranded adoption (manual move onto the park workspace)
disp "hl.dsp.window.move({ window = \"address:$C\", workspace = \"$PARK\", follow = false })"; sleep 0.6
check "S  window moved to $PARK by hand is adopted" eq "$(status_field recovered)" "1"
ipc restoreAll >/dev/null; sleep 0.4

# 8b. parked process death (not relaunchable -> entry removed)
D=$(spawn); dpid=$(prop_of "$D" pid)
ipc parkWindow "$D" >/dev/null; sleep 0.3; kill "$dpid"; sleep 0.8
check "P  dead parked window is dropped, not zombie" eq "$(status_field parked)|$(status_field undo)" "0|0"

# bar widget state follows the service
ipc parkWindow "$A" >/dev/null; sleep 0.4
bar_json=$(ipc status | python3 -c 'import json,sys; b=json.load(sys.stdin).get("bar") or {}; print("ok" if isinstance(b.get("placed"), bool) and "tray" in b else "bad")')
check "B  status reports bar placement and settings"  eq "$bar_json" "ok"
check "B  restoreAddress (tray click path) restores the window" eq "$(ipc restoreAddress "$A" >/dev/null; sleep 0.5; ws_of "$A")" "$home_ws"

# 20. park timeout: expiry, enable-grace, restore-cancels
ipc setSetting parkTimeout 5 >/dev/null; sleep 0.3
check "20 timeout value reported in status" eq "$(status_field parkTimeout)" "5"
W=$(spawn)
ipc parkWindow "$W" >/dev/null; sleep 7
check "20 parked window auto-closes after the timeout" eq "$(ws_of "$W")|$(status_field parked)" "|0"
ipc setSetting parkTimeout 0 >/dev/null
# Enabling later grants a full interval from enable time, not park time.
G=$(spawn)
ipc parkWindow "$G" >/dev/null; sleep 3
ipc setSetting parkTimeout 5 >/dev/null; sleep 3
check "20 enabling grants a full timeout from enable time" eq "$(status_field parked)" "1"
sleep 4
check "20 window expires once the post-enable interval elapses" eq "$(ws_of "$G")|$(status_field parked)" "|0"
# Restoring before the deadline cancels the clock.
U=$(spawn)
ipc parkWindow "$U" >/dev/null; sleep 2
ipc undo >/dev/null; sleep 6
check "20 restoring before the deadline cancels the timeout" eq "$(ws_of "$U")" "$home_ws"
ipc setSetting parkTimeout 0 >/dev/null; sleep 0.3

# hidden workspace agrees with the model at the end
hidden=$(clients | python3 -c "import json,sys; print(sum(1 for c in json.load(sys.stdin) if c['workspace']['name']=='$PARK'))")
check "Z  nothing left on $PARK"                eq "$hidden" "0"

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
