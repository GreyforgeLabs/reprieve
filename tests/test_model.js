#!/usr/bin/env node
"use strict"

const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "..", "ReprieveModel.js"))

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL:", name)
    throw e
  }
}

function snap(extra) {
  return Object.assign({
    address: "0xabc",
    class: "google-chrome",
    title: "Inbox - Gmail",
    workspace: "2",
    floating: false,
    fullscreen: 0,
    fullscreenClient: 0,
    pid: 4242
  }, extra || {})
}

const SESSION = "efb5099_1788996183_413474032"

// --------------------------------------------------------------- sanitizing

test("address sanitization", () => {
  assert.strictEqual(M.normalizeAddress("abc"), "0xabc")
  assert.strictEqual(M.normalizeAddress("0xABC"), "0xabc")
  assert.strictEqual(M.normalizeAddress("0x0000abc"), "0xabc")
  assert.strictEqual(M.normalizeAddress("55d35b34c540"), "0x55d35b34c540")
  assert.strictEqual(M.normalizeAddress('0xabc" }); os.execute("id'), "")
  assert.strictEqual(M.normalizeAddress("0x"), "")
  assert.strictEqual(M.normalizeAddress("0xzz"), "")
  assert.strictEqual(M.normalizeAddress("0x" + "f".repeat(17)), "")
  assert.strictEqual(M.normalizeAddress(null), "")
  assert.strictEqual(M.normalizeAddress({}), "")
})

test("workspace sanitization", () => {
  assert.strictEqual(M.normalizeWorkspace("3"), "3")
  assert.strictEqual(M.normalizeWorkspace("special:reprieve"), "special:reprieve")
  assert.strictEqual(M.normalizeWorkspace("name:web"), "name:web")
  assert.strictEqual(M.normalizeWorkspace('2" }) os.exit() --'), "")
  assert.strictEqual(M.normalizeWorkspace("a b"), "")
  assert.strictEqual(M.normalizeWorkspace("x".repeat(65)), "")
  assert.strictEqual(M.normalizeWorkspace(""), "")
})

test("label sanitization", () => {
  assert.strictEqual(M.sanitizeLabel("a\nb\tc", 52), "abc")
  assert.strictEqual(M.sanitizeLabel("bell", 52), "bell")
  assert.ok(M.sanitizeLabel("x".repeat(200), 52).length <= 52)
  assert.strictEqual(M.sanitizeLabel("", 52), "window")
  assert.strictEqual(M.toastLabel({ title: "Inbox - Gmail - Google Chrome" }), "Inbox - Gmail - Google Chrome")
  assert.ok(M.toastLabel({ title: "x".repeat(80) }).length <= 32)
  assert.strictEqual(M.sanitizeClass("goo gle\nchrome"), "googlechrome")
  assert.ok(M.sanitizeClass("c".repeat(500)).length <= 128)
})

// ------------------------------------------------------------------ parking

test("park / excluded classes / special workspaces", () => {
  const s = M.createState({ max: 3 })
  assert.strictEqual(s.max, 3)
  assert.ok(M.canPark(snap(), s))
  assert.ok(!M.canPark(snap({ class: "org.omarchy.screensaver" }), s))
  assert.ok(!M.canPark(snap({ class: "org.omarchy.lock" }), s))
  assert.ok(!M.canPark(snap({ class: "org.omarchy.polkit" }), s))
  assert.ok(!M.canPark(snap({ workspace: "special:scratchpad" }), s))
  assert.ok(!M.canPark(snap({ workspace: "special:reprieve" }), s))
  assert.ok(!M.canPark(snap({ address: "" }), s))
  assert.ok(!M.canPark(snap({ address: "nope" }), s))
  assert.ok(!M.canPark(snap({ class: "" }), s))
  const r = M.pushPark(s, snap({ class: "org.omarchy.lock" }))
  assert.strictEqual(r.reason, "excluded")
  assert.strictEqual(r.state.undo.length, 0)
})

test("park records exact state and sequence", () => {
  const r = M.pushPark(M.createState(), snap({ floating: true, fullscreen: 1, fullscreenClient: 1 }))
  assert.strictEqual(r.reason, "parked")
  const a = r.state.undo[0]
  assert.strictEqual(a.type, "park")
  assert.strictEqual(a.address, "0xabc")
  assert.strictEqual(a.workspace, "2")
  assert.strictEqual(a.floating, true)
  assert.strictEqual(a.fullscreen, 1)
  assert.strictEqual(a.fullscreenClient, 1)
  assert.strictEqual(a.pid, 4242)
  assert.strictEqual(a.sequence, 1)
  assert.strictEqual(a.recovered, false)
  assert.strictEqual(r.state.sequence, 1)
  assert.deepStrictEqual(r.kills, [])
  // Bogus metadata is clamped, never trusted.
  const b = M.pushPark(M.createState(), snap({ fullscreen: 99, fullscreenClient: -1, pid: "abc" })).state.undo[0]
  assert.strictEqual(b.fullscreen, 0)
  assert.strictEqual(b.fullscreenClient, 0)
  assert.strictEqual(b.pid, 0)
})

test("stack cap closes the oldest parked window deterministically", () => {
  let r = M.pushPark(M.createState({ max: 3 }), snap())
  r = M.pushPark(r.state, snap({ address: "0x1", title: "One" }))
  r = M.pushPark(r.state, snap({ address: "0x2", title: "Two" }))
  assert.deepStrictEqual(r.kills, [])
  r = M.pushPark(r.state, snap({ address: "0x3", title: "Three" }))
  assert.strictEqual(r.state.undo.length, 3)
  assert.deepStrictEqual(r.kills, ["0xabc"])
  assert.deepStrictEqual(M.parkedAddresses(r.state), ["0x1", "0x2", "0x3"])
  assert.strictEqual(M.clampMax(99), 20)
  assert.strictEqual(M.clampMax(0), 1)
  assert.strictEqual(M.clampMax("x"), 10)
})

test("re-parking a tracked address replaces the stale entry", () => {
  let r = M.pushPark(M.createState(), snap({ address: "0x1", workspace: "1" }))
  r = M.pushPark(r.state, snap({ address: "0x1", workspace: "4" }))
  assert.strictEqual(r.state.undo.length, 1)
  assert.strictEqual(r.state.undo[0].workspace, "4")
})

// ---------------------------------------------------------------- undo/redo

test("undo restores to original workspace with exact state, redo re-parks", () => {
  let r = M.pushPark(M.createState({ max: 3 }), snap({ address: "0x1", title: "One", floating: true, fullscreen: 2, fullscreenClient: 2 }))
  r = M.pushPark(r.state, snap({ address: "0x2", title: "Two" }))
  const u = M.undo(r.state)
  assert.strictEqual(u.action.label, "Two")
  assert.strictEqual(u.effects[0].type, "restore")
  assert.strictEqual(u.effects[0].workspace, "2")
  assert.strictEqual(u.effects[0].here, false)
  assert.strictEqual(u.state.undo.length, 1)
  assert.strictEqual(u.state.redo.length, 1)
  const u2 = M.undo(u.state)
  assert.strictEqual(u2.effects[0].floating, true)
  assert.strictEqual(u2.effects[0].fullscreen, 2)
  assert.strictEqual(u2.effects[0].fullscreenClient, 2)
  const red = M.redo(u.state)
  assert.strictEqual(red.effects[0].type, "park")
  assert.strictEqual(red.effects[0].address, "0x2")
  assert.strictEqual(red.effects[0].workspace, M.PARK_WORKSPACE)
  assert.strictEqual(red.state.undo.length, 2)
  assert.strictEqual(red.state.redo.length, 0)
  // A new park clears redo.
  const n = M.pushPark(M.undo(red.state).state, snap({ address: "0x9" }))
  assert.strictEqual(n.state.redo.length, 0)
  // Empty stacks are no-ops.
  assert.strictEqual(M.undo(M.createState()).action, null)
  assert.strictEqual(M.redo(M.createState()).action, null)
})

test("arbitrary restore and restore here", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", title: "One" })).state
  s = M.pushPark(s, snap({ address: "0x2", title: "Two" })).state
  s = M.pushPark(s, snap({ address: "0x3", title: "Three" })).state
  let u = M.undoAt(s, 1, null)
  assert.strictEqual(u.action.address, "0x2")
  assert.deepStrictEqual(u.state.undo.map(a => a.address), ["0x1", "0x3"])
  assert.strictEqual(u.effects[0].workspace, "2")
  u = M.undoAt(s, 0, { workspace: "5" })
  assert.strictEqual(u.effects[0].workspace, "5")
  assert.strictEqual(u.effects[0].here, true)
  // "Here" onto a special workspace falls back to the recorded one.
  u = M.undoAt(s, 0, { workspace: "special:magic" })
  assert.strictEqual(u.effects[0].workspace, "2")
  // Hostile "here" is dropped.
  u = M.undoAt(s, 0, { workspace: '1" })' })
  assert.strictEqual(u.effects[0].workspace, "2")
  assert.strictEqual(M.undoAt(s, 99, null).action, null)
  assert.strictEqual(M.undoAt(s, -1, null).action, null)
})

test("undoAt rejects NaN, fractional and infinite indexes without touching redo", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", title: "One" })).state
  for (const bad of [NaN, 1.5, Infinity, -Infinity, "x", undefined]) {
    const r = M.undoAt(s, Number(bad), null)
    assert.strictEqual(r.action, null)
    assert.deepStrictEqual(r.effects, [])
    assert.deepStrictEqual(r.state.redo, [])
  }
  assert.deepStrictEqual(M.parkedAddresses(s), ["0x1"])
})

test("redo overflow closes the oldest", () => {
  let s = M.createState({ max: 2 })
  s = M.pushPark(s, snap({ address: "0x1" })).state
  s = M.pushPark(s, snap({ address: "0x2" })).state
  const u = M.undo(s)
  const s2 = M.pushPark(u.state, snap({ address: "0x3" })).state // undo cleared redo, so re-add
  assert.strictEqual(s2.redo.length, 0)
  let t = M.createState({ max: 2 })
  t = M.pushPark(t, snap({ address: "0x1" })).state
  t = M.pushPark(t, snap({ address: "0x2" })).state
  const undone = M.undo(t)
  // Put another one on top via a state that still has redo (use clone trick)
  const withRedo = M.cloneState(undone.state)
  withRedo.undo = withRedo.undo.concat([M.pushPark(M.createState(), snap({ address: "0x7" })).state.undo[0]])
  const red = M.redo(withRedo)
  assert.strictEqual(red.state.undo.length, 2)
  const closes = red.effects.filter(e => e.type === "close").map(e => e.address)
  assert.deepStrictEqual(closes, ["0x1"])
})

// ---------------------------------------------------------------- relaunch

test("relaunch allowlist", () => {
  assert.deepStrictEqual(M.relaunchCommand(snap()), ["omarchy-launch-browser"])
  assert.deepStrictEqual(M.relaunchCommand(snap({ class: "firefox" })), ["omarchy-launch-browser"])
  assert.deepStrictEqual(
    M.relaunchCommand(snap({ class: "chrome-teams.cloud.microsoft__-Default" })),
    ["omarchy-launch-webapp", "https://teams.cloud.microsoft"]
  )
  assert.strictEqual(M.relaunchCommand(snap({ class: "steam_app_1" })), null)
  assert.strictEqual(M.relaunchCommand(snap({ class: "Alacritty" })), null)
  assert.strictEqual(M.relaunchCommand(snap({ class: "com.mitchellh.ghostty" })), null)
  assert.strictEqual(M.relaunchCommand(snap({ class: "chrome-evil.com/x__-Default" })), null)
  assert.strictEqual(M.relaunchCommand(snap({ class: "chrome-..__-Default" })), null)
  assert.strictEqual(M.relaunchCommand(snap({ class: "chrome-a..b__-Default" })), null)
  assert.strictEqual(M.relaunchCommand({ class: "google-chrome --evil" }), null)
  assert.strictEqual(M.relaunchCommand(null), null)
  const r = M.pushRelaunch(M.createState(), snap({ address: "0xdead" }))
  assert.strictEqual(r.reason, "recorded")
  const u = M.undo(r.state)
  assert.strictEqual(u.effects[0].type, "relaunch")
  assert.deepStrictEqual(M.redo(u.state).effects, [])
  assert.strictEqual(M.pushRelaunch(M.createState(), snap({ class: "foot" })).reason, "skip")
})

// ------------------------------------------------------------- dead windows

test("dead parked-window conversion", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", class: "google-chrome", title: "Gmail" })).state
  s = M.pushPark(s, snap({ address: "0x2", class: "foot", title: "shell" })).state
  const a = M.markDead(s, "0x1")
  assert.strictEqual(a.converted, true)
  assert.strictEqual(a.removed, false)
  assert.strictEqual(a.state.undo.length, 2)
  assert.strictEqual(a.state.undo[0].type, "relaunch")
  assert.strictEqual(a.state.undo[0].address, "")
  assert.strictEqual(a.state.undo[0].sequence, 1)
  assert.deepStrictEqual(M.parkedAddresses(a.state), ["0x2"])
  const b = M.markDead(a.state, "0x2")
  assert.strictEqual(b.converted, false)
  assert.strictEqual(b.removed, true)
  assert.strictEqual(b.state.undo.length, 1)
  assert.strictEqual(M.markDead(b.state, "0x999").action, null)
  assert.strictEqual(M.markDead(b.state, "garbage").state, b.state)
})

test("dropAddress / findParked", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1" })).state
  s = M.pushPark(s, snap({ address: "0x2" })).state
  assert.strictEqual(M.findParked(s, "0x2"), 1)
  assert.strictEqual(M.findParked(s, "0x3"), -1)
  s = M.dropAddress(s, "0x1")
  assert.deepStrictEqual(M.parkedAddresses(s), ["0x2"])
  const summary = M.statusSummary(s)
  assert.strictEqual(summary.undo, 1)
  assert.strictEqual(summary.parked, 1)
  assert.strictEqual(summary.recovered, 0)
})

// ------------------------------------------------------ restore all / reset

test("restore all restores every live window oldest-first", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", workspace: "1" })).state
  s = M.pushRelaunch(s, snap({ address: "0xdead" })).state
  s = M.pushPark(s, snap({ address: "0x2", workspace: "" })).state
  const r = M.restoreAll(s, "7")
  assert.strictEqual(r.actions.length, 2)
  assert.deepStrictEqual(r.effects.map(e => [e.address, e.workspace]), [["0x1", "1"], ["0x2", "7"]])
  assert.strictEqual(r.state.undo.length, 1)
  assert.strictEqual(r.state.undo[0].type, "relaunch")
  assert.strictEqual(r.state.redo.length, 2)
  assert.deepStrictEqual(M.parkedAddresses(r.state), [])
})

test("clear refuses to orphan live parked windows", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1" })).state
  const refused = M.clear(s)
  assert.strictEqual(refused.ok, false)
  assert.strictEqual(refused.live, 1)
  assert.deepStrictEqual(M.parkedAddresses(refused.state), ["0x1"])
  const empty = M.clear(M.pushRelaunch(M.createState(), snap({ address: "0xdead" })).state)
  assert.strictEqual(empty.ok, true)
  assert.strictEqual(empty.state.undo.length, 0)
})

test("reset restores everything and preserves settings", () => {
  let s = M.createState({ max: 5 })
  s = M.pushPark(s, snap({ address: "0x1", workspace: "3" })).state
  s = M.pushPark(s, snap({ address: "0x2", workspace: "" })).state
  const r = M.reset(s, "2")
  assert.deepStrictEqual(r.effects.map(e => [e.type, e.address, e.workspace]), [["restore", "0x1", "3"], ["restore", "0x2", "2"]])
  assert.strictEqual(r.state.undo.length, 0)
  assert.strictEqual(r.state.redo.length, 0)
  assert.strictEqual(r.state.max, 5)
  assert.strictEqual(r.state.sequence, s.sequence)
})

// -------------------------------------------------------------------- media

test("media payload sanitizing and attach", () => {
  assert.deepStrictEqual(M.sanitizeMedia({ muted: [{ index: 4, pid: 9 }], paused: ["org.mpris.MediaPlayer2.spotify"] }),
    { muted: [{ index: 4, pid: 9 }], paused: ["org.mpris.MediaPlayer2.spotify"] })
  assert.strictEqual(M.sanitizeMedia({ muted: [], paused: [] }), null)
  assert.strictEqual(M.sanitizeMedia({ muted: [{ index: -1 }], paused: ["spotify; rm -rf"] }), null)
  assert.strictEqual(M.sanitizeMedia("nope"), null)
  const big = { muted: Array.from({ length: 100 }, (_, i) => ({ index: i })), paused: Array.from({ length: 100 }, (_, i) => "org.mpris.MediaPlayer2.p" + i) }
  const clean = M.sanitizeMedia(big)
  assert.strictEqual(clean.muted.length, 32)
  assert.strictEqual(clean.paused.length, 16)
  let s = M.pushPark(M.createState(), snap({ address: "0x3" })).state
  s = M.attachMedia(s, "0x3", { muted: [{ index: 4, pid: 1 }], paused: ["org.mpris.MediaPlayer2.spotify"] })
  assert.deepStrictEqual(s.undo[0].media, { muted: [{ index: 4, pid: 1 }], paused: ["org.mpris.MediaPlayer2.spotify"] })
  assert.strictEqual(M.attachMedia(s, "zzz", {}), s)
})

// ------------------------------------------------------------------ journal

test("journal round trip persists only recovery data", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", title: "Secret Title", floating: true, fullscreen: 1, fullscreenClient: 1, media: { muted: [{ index: 3, pid: 4242 }], paused: [] } })).state
  s = M.pushRelaunch(s, snap({ address: "0xdead" })).state
  const j = M.toJournal(s, SESSION)
  assert.strictEqual(j.schema, 1)
  assert.strictEqual(j.session, SESSION)
  assert.strictEqual(j.entries.length, 1)
  const e = j.entries[0]
  assert.deepStrictEqual(Object.keys(e).sort(), ["address", "class", "floating", "fullscreen", "fullscreenClient", "media", "parkedAt", "pid", "sequence", "workspace"])
  assert.strictEqual(JSON.stringify(j).indexOf("Secret Title"), -1)
  assert.strictEqual(JSON.stringify(j).indexOf("argv"), -1)
  const p = M.parseJournal(JSON.stringify(j), SESSION)
  assert.strictEqual(p.status, "ok")
  assert.strictEqual(p.entries.length, 1)
  assert.strictEqual(p.entries[0].fullscreen, 1)
  assert.strictEqual(p.entries[0].floating, true)
  assert.deepStrictEqual(p.entries[0].media, { muted: [{ index: 3, pid: 4242 }], paused: [] })
})

test("journal rejects malformed, oversized, wrong-schema and foreign-session input", () => {
  assert.strictEqual(M.parseJournal("", SESSION).status, "empty")
  assert.strictEqual(M.parseJournal("   \n", SESSION).status, "empty")
  assert.strictEqual(M.parseJournal("{not json", SESSION).status, "invalid")
  assert.strictEqual(M.parseJournal("[]", SESSION).status, "invalid")
  assert.strictEqual(M.parseJournal("null", SESSION).status, "invalid")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 2, session: SESSION, entries: [] }), SESSION).status, "invalid")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 1, session: SESSION, entries: "x" }), SESSION).status, "invalid")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 1, session: "other", entries: [] }), SESSION).status, "stale")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 1, session: SESSION, entries: [] }), "").status, "stale")
  const huge = JSON.stringify({ schema: 1, session: SESSION, entries: [], pad: "x".repeat(M.JOURNAL_MAX_BYTES) })
  assert.strictEqual(M.parseJournal(huge, SESSION).status, "invalid")
  // Hostile entries are dropped or re-typed, never passed through.
  const hostile = JSON.stringify({ schema: 1, session: SESSION, sequence: "9e99", entries: [
    { address: '0x1"); os.execute("id', workspace: "1" },
    { address: "0x2", workspace: 'x" })', class: "a\nb", floating: "yes", fullscreen: 7, pid: -5, sequence: 3, argv: ["rm"], env: { A: 1 } },
    "junk", null, 42
  ].concat(Array.from({ length: 200 }, (_, i) => ({ address: "0x" + (100 + i).toString(16) }))) })
  const p = M.parseJournal(hostile, SESSION)
  assert.strictEqual(p.status, "ok")
  assert.ok(p.entries.length <= M.JOURNAL_MAX_ENTRIES)
  const e = p.entries.find(x => x.address === "0x2")
  assert.strictEqual(e.workspace, "")
  assert.strictEqual(e.class, "ab")
  assert.strictEqual(e.floating, false)
  assert.strictEqual(e.fullscreen, 0)
  assert.strictEqual(e.pid, 0)
  assert.strictEqual(e.argv, undefined)
  assert.strictEqual(e.env, undefined)
  assert.strictEqual(p.sequence, 0)
})

// ---------------------------------------------------------------- reconcile

function live(addr, ws, extra) {
  return Object.assign({ address: addr, workspace: ws, class: "foot", title: "t " + addr, pid: 7, floating: false }, extra || {})
}

test("reconcile: same-session journal recovers parked windows in order", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", class: "foot", title: "One", workspace: "1" })).state
  s = M.pushPark(s, snap({ address: "0x2", class: "chromium", title: "Two", workspace: "2", fullscreen: 1, fullscreenClient: 1 })).state
  const j = M.parseJournal(JSON.stringify(M.toJournal(s, SESSION)), SESSION)
  const fresh = M.createState()
  const r = M.reconcile(fresh, j.entries, [live("0x1", "special:reprieve"), live("0x2", "special:reprieve", { title: "Two - Chromium" }), live("0x3", "4")], j.sequence)
  assert.deepStrictEqual(r.state.undo.map(a => a.address), ["0x1", "0x2"])
  assert.strictEqual(r.state.undo[1].workspace, "2")
  assert.strictEqual(r.state.undo[1].fullscreen, 1)
  assert.strictEqual(r.state.undo[1].recovered, false)
  assert.strictEqual(r.state.undo[1].label, "Two - Chromium")
  assert.deepStrictEqual(r.report.kept, ["0x1", "0x2"])
  assert.deepStrictEqual(r.report.recovered, [])
  assert.strictEqual(r.state.sequence, 2)
  // Immediately undoable, newest first.
  const u = M.undo(r.state)
  assert.strictEqual(u.action.address, "0x2")
  assert.strictEqual(u.effects[0].workspace, "2")
})

test("reconcile: stranded live windows are exposed as recovered", () => {
  const r = M.reconcile(M.createState(), [], [live("0x9", "special:reprieve", { class: "foot", title: "lost shell" }), live("0x3", "1")], 0)
  assert.strictEqual(r.state.undo.length, 1)
  const a = r.state.undo[0]
  assert.strictEqual(a.recovered, true)
  assert.strictEqual(a.workspace, "")
  assert.strictEqual(a.label, "lost shell")
  assert.deepStrictEqual(r.report.recovered, ["0x9"])
  assert.strictEqual(M.statusSummary(r.state).recovered, 1)
  // Restore falls back to the current workspace.
  const u = M.undoAt(r.state, 0, { workspace: "5" })
  assert.strictEqual(u.effects[0].workspace, "5")
  // Even a window with no class is kept rather than lost.
  const r2 = M.reconcile(M.createState(), [], [live("0x8", "special:reprieve", { class: "", title: "" })], 0)
  assert.strictEqual(r2.state.undo.length, 1)
  assert.strictEqual(r2.state.undo[0].class, "window")
})

test("reconcile: missing live address is converted or dropped, never zombie", () => {
  const entries = [
    { address: "0xa", workspace: "1", class: "google-chrome", floating: false, fullscreen: 0, fullscreenClient: 0, pid: 1, sequence: 1, media: null, recovered: false },
    { address: "0xb", workspace: "1", class: "foot", floating: false, fullscreen: 0, fullscreenClient: 0, pid: 2, sequence: 2, media: null, recovered: false },
    { address: "0xc", workspace: "1", class: "foot", floating: false, fullscreen: 0, fullscreenClient: 0, pid: 3, sequence: 3, media: null, recovered: false }
  ]
  const r = M.reconcile(M.createState(), entries, [live("0xc", "3")], 3)
  assert.strictEqual(r.state.undo.length, 1)
  assert.strictEqual(r.state.undo[0].type, "relaunch")
  assert.strictEqual(r.state.undo[0].class, "google-chrome")
  assert.deepStrictEqual(r.report.converted, ["0xa"])
  assert.deepStrictEqual(r.report.dropped.sort(), ["0xb", "0xc"])
  assert.deepStrictEqual(M.parkedAddresses(r.state), [])
})

test("reconcile: partial journal plus in-memory state merges without duplicates", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1", class: "foot", workspace: "1" })).state
  const entries = [{ address: "0x1", workspace: "9", class: "foot", floating: false, fullscreen: 0, fullscreenClient: 0, pid: 1, sequence: 1, media: null, recovered: false },
                   { address: "0x2", workspace: "2", class: "foot", floating: true, fullscreen: 0, fullscreenClient: 0, pid: 2, sequence: 2, media: null, recovered: false }]
  const r = M.reconcile(s, entries, [live("0x1", "special:reprieve"), live("0x2", "special:reprieve"), live("0x5", "special:reprieve")], 2)
  assert.deepStrictEqual(r.state.undo.map(a => a.address), ["0x1", "0x2", "0x5"])
  assert.strictEqual(r.state.undo[0].workspace, "1") // in-memory wins
  assert.strictEqual(r.state.undo[1].floating, true)
  assert.strictEqual(r.state.undo[2].recovered, true)
  assert.strictEqual(r.state.sequence, 3)
  // Idempotent.
  const again = M.reconcile(r.state, [], [live("0x1", "special:reprieve"), live("0x2", "special:reprieve"), live("0x5", "special:reprieve")], 0)
  assert.deepStrictEqual(again.state.undo.map(a => a.address), ["0x1", "0x2", "0x5"])
  assert.deepStrictEqual(again.report.recovered, [])
})

test("reconcile: excluded classes on the park workspace are left alone", () => {
  const r = M.reconcile(M.createState(), [], [live("0x1", "special:reprieve", { class: "org.omarchy.lock" })], 0)
  assert.strictEqual(r.state.undo.length, 1) // still exposed: a stranded window is worse than an odd entry
})

test("pushRecovered adopts a stranded window without closing anything", () => {
  let s = M.createState({ max: 1 })
  s = M.pushPark(s, snap({ address: "0x1" })).state
  const r = M.pushRecovered(s, { address: "0x2", class: "foot", title: "x", workspace: "special:reprieve" })
  assert.strictEqual(r.reason, "recovered")
  assert.strictEqual(r.state.undo.length, 2)
  assert.strictEqual(r.action.recovered, true)
  assert.strictEqual(r.action.workspace, "")
  assert.strictEqual(M.pushRecovered(r.state, { address: "0x2", class: "foot" }).reason, "tracked")
  assert.strictEqual(M.pushRecovered(r.state, { address: "nope", class: "foot" }).reason, "invalid")
  assert.strictEqual(M.pushRecovered(r.state, { address: "0x3", class: "org.omarchy.lock" }).reason, "excluded")
})

// ------------------------------------------------------------- park timeout

test("parkTimeout is off by default and clamps to 5-120", () => {
  assert.strictEqual(M.DEFAULT_PARK_TIMEOUT, 0)
  assert.strictEqual(M.MIN_PARK_TIMEOUT, 5)
  assert.strictEqual(M.MAX_PARK_TIMEOUT, 120)
  assert.strictEqual(M.createState().parkTimeout, 0)
  assert.strictEqual(M.clampParkTimeout(undefined), 0)
  assert.strictEqual(M.clampParkTimeout("off"), 0)
  assert.strictEqual(M.clampParkTimeout(0), 0)
  assert.strictEqual(M.clampParkTimeout(-30), 0)
  assert.strictEqual(M.clampParkTimeout(1), 5)
  assert.strictEqual(M.clampParkTimeout(4), 5)
  assert.strictEqual(M.clampParkTimeout(5), 5)
  assert.strictEqual(M.clampParkTimeout(30), 30)
  assert.strictEqual(M.clampParkTimeout(120), 120)
  assert.strictEqual(M.clampParkTimeout(500), 120)
  assert.strictEqual(M.createState({ parkTimeout: 30 }).parkTimeout, 30)
  assert.strictEqual(M.createState({ parkTimeout: 3 }).parkTimeout, 5)
  // Survives clone and reset.
  const cloned = M.cloneState(M.createState({ parkTimeout: 45 }))
  assert.strictEqual(cloned.parkTimeout, 45)
})

test("pushPark stamps parkedAt and re-park refreshes it", () => {
  const r = M.pushPark(M.createState(), snap(), 1000000)
  assert.strictEqual(r.state.undo[0].parkedAt, 1000000)
  const r2 = M.pushPark(r.state, snap(), 2000000)
  assert.strictEqual(r2.state.undo.length, 1)
  assert.strictEqual(r2.state.undo[0].parkedAt, 2000000)
})

test("expireParked only drops timed-out undo entries", () => {
  let s = M.createState({ parkTimeout: 10 })
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  s = M.pushPark(s, snap({ address: "0x2" }), 1005000).state
  // Nothing expired yet (9s and 4s old).
  let r = M.expireParked(s, 1009000, 10)
  assert.deepStrictEqual(r.expired, [])
  assert.strictEqual(r.state.undo.length, 2)
  // At 11s the first entry expires; the second is only 6s old.
  r = M.expireParked(s, 1011000, 10)
  assert.deepStrictEqual(r.expired.map(a => a.address), ["0x1"])
  assert.deepStrictEqual(r.state.undo.map(a => a.address), ["0x2"])
  // Disabled timeout never expires.
  r = M.expireParked(s, 9999999999, 0)
  assert.deepStrictEqual(r.expired, [])
  assert.strictEqual(r.state.undo.length, 2)
})

test("expireParked exempts unstamped entries and leaves redo alone", () => {
  let s = M.createState({ parkTimeout: 10 })
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  // Simulate a pre-timeout journal entry with no stamp.
  s.undo[0].parkedAt = 0
  const r = M.expireParked(s, 9999999999, 10)
  assert.deepStrictEqual(r.expired, [])
  assert.strictEqual(r.state.undo.length, 1)
  // Redo entries are never expired even when ancient.
  let s2 = M.createState({ parkTimeout: 10 })
  s2 = M.pushPark(s2, snap({ address: "0x9" }), 1000000).state
  const undone = M.undo(s2)
  assert.strictEqual(undone.state.redo.length, 1)
  const r2 = M.expireParked(undone.state, 9999999999, 10)
  assert.deepStrictEqual(r2.expired, [])
  assert.strictEqual(r2.state.redo.length, 1)
})

test("parkTimeout survives journal round-trip", () => {
  let s = M.createState({ parkTimeout: 10 })
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  const journal = M.toJournal(s, SESSION)
  assert.strictEqual(journal.entries[0].parkedAt, 1000000)
  const parsed = M.parseJournal(JSON.stringify({ schema: 1, session: SESSION, sequence: 1, entries: journal.entries }), SESSION)
  assert.strictEqual(parsed.status, "ok")
  assert.strictEqual(parsed.entries[0].parkedAt, 1000000)
  // Pre-timeout journals without the field parse as exempt, not expired.
  const legacy = M.parseJournal(JSON.stringify({ schema: 1, session: SESSION, sequence: 1, entries: [{ address: "0x2", workspace: "2", class: "foot", sequence: 2 }] }), SESSION)
  assert.strictEqual(legacy.status, "ok")
  assert.strictEqual(legacy.entries[0].parkedAt, 0)
})

test("reconcile keeps unstamped journal entries exempt from expiry", () => {
  const live = (address, workspace, extra) => Object.assign({ address: address, workspace: workspace, class: "foot", title: "t", pid: 1, floating: false, fullscreen: 0, fullscreenClient: 0 }, extra || {})
  const s = M.createState({ parkTimeout: 10 })
  const legacy = [{ address: "0x1", workspace: "2", class: "foot", sequence: 1, parkedAt: 0 }]
  const r = M.reconcile(s, legacy, [live("0x1", "special:reprieve")], 1)
  assert.strictEqual(r.state.undo.length, 1)
  assert.strictEqual(r.state.undo[0].parkedAt, 0)
  const expired = M.expireParked(r.state, 9999999999, 10)
  assert.deepStrictEqual(expired.expired, [])
})

test("restampParked grants a full timeout from enable time", () => {
  let s = M.createState({ parkTimeout: 0 })
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  s = M.pushPark(s, snap({ address: "0x2" }), 1001000).state
  // Enabling much later would expire both on the spot without grace.
  assert.strictEqual(M.expireParked(s, 2000000, 10).expired.length, 2)
  const graced = M.restampParked(s, 2000000)
  assert.strictEqual(graced.undo[0].parkedAt, 2000000)
  assert.strictEqual(graced.undo[1].parkedAt, 2000000)
  assert.deepStrictEqual(M.expireParked(graced, 2009000, 10).expired, [])
  assert.strictEqual(M.expireParked(graced, 2010000, 10).expired.length, 2)
})

test("restampParked leaves exempt entries, redo and other types alone", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  s.undo[0].parkedAt = 0 // pre-timeout history stays exempt
  s = M.pushRelaunch(s, snap({ address: "0xdead" })).state
  const graced = M.restampParked(s, 2000000)
  assert.strictEqual(graced, s) // nothing stamped: same ref
  assert.strictEqual(s.undo[0].parkedAt, 0)
  // Redo entries describe visible windows: never restamped, never expired.
  const u = M.undo(M.pushPark(M.createState(), snap({ address: "0x2" }), 1000000).state)
  const graced2 = M.restampParked(u.state, 2000000)
  assert.strictEqual(graced2, u.state)
  assert.strictEqual(u.state.redo[0].parkedAt, 1000000)
  assert.deepStrictEqual(M.expireParked(u.state, 9999999999, 10).expired, [])
  assert.strictEqual(M.restampParked(null, 2000000), null)
  assert.strictEqual(M.restampParked(s, -5), s)
})

test("redo restarts the clock: re-hiding starts a new interval", () => {
  let s = M.createState()
  s = M.pushPark(s, snap({ address: "0x1" }), 1000000).state
  const u = M.undo(s) // window visible again; entry waits in redo
  const red = M.redo(u.state, 2000000)
  assert.strictEqual(red.state.undo[0].parkedAt, 2000000)
  // Old stamp would have expired at 1010000; new one survives past it.
  assert.deepStrictEqual(M.expireParked(red.state, 1500000, 10).expired, [])
  assert.strictEqual(M.expireParked(red.state, 2010000, 10).expired.length, 1)
})

test("reconcile with timeout on grants a fresh interval after restart", () => {
  const rl = (address, workspace, extra) => Object.assign({ address: address, workspace: workspace, class: "foot", title: "t", pid: 1, floating: false, fullscreen: 0, fullscreenClient: 0 }, extra || {})
  let s = M.createState({ parkTimeout: 10 })
  s = M.pushPark(s, snap({ address: "0x1", class: "foot", workspace: "1" }), 1000000).state
  const j = M.parseJournal(JSON.stringify(M.toJournal(s, SESSION)), SESSION)
  // Without grace the old stamp would expire on the first sweep.
  assert.strictEqual(M.expireParked(s, 2000000, 10).expired.length, 1)
  const r = M.reconcile(M.createState({ parkTimeout: 10 }), j.entries, [rl("0x1", "special:reprieve")], j.sequence, 2000000)
  assert.strictEqual(r.state.undo.length, 1)
  assert.strictEqual(r.state.undo[0].parkedAt, 2000000)
  assert.deepStrictEqual(M.expireParked(r.state, 2009000, 10).expired, [])
  // Timeout off: stamps survive untouched.
  const r2 = M.reconcile(M.createState(), j.entries, [rl("0x1", "special:reprieve")], j.sequence, 2000000)
  assert.strictEqual(r2.state.undo[0].parkedAt, 1000000)
  // Unstamped legacy entries stay exempt even with the timeout on.
  const legacy = [{ address: "0x2", workspace: "2", class: "foot", sequence: 9, parkedAt: 0 }]
  const r3 = M.reconcile(M.createState({ parkTimeout: 10 }), legacy, [rl("0x2", "special:reprieve")], 9, 2000000)
  assert.strictEqual(r3.state.undo[0].parkedAt, 0)
  assert.deepStrictEqual(M.expireParked(r3.state, 9999999999, 10).expired, [])
})

console.log("ReprieveModel tests passed (" + passed + ")")
