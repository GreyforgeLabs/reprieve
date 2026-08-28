#!/usr/bin/env node
"use strict"

const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "..", "UndoModel.js"))

function snap(extra) {
  return Object.assign({
    address: "0xabc",
    class: "google-chrome",
    title: "Inbox - Gmail",
    workspace: "2",
    floating: false,
    fullscreen: 0,
    command: ["/usr/bin/google-chrome-stable"],
    cwd: "/home/x"
  }, extra || {})
}

let s = M.createState({ max: 3 })
assert.strictEqual(s.max, 3)
assert.strictEqual(M.normalizeAddress("abc"), "0xabc")
assert.strictEqual(M.normalizeAddress("0xABC"), "0xABC")
assert.ok(M.canPark(snap(), s))
assert.ok(!M.canPark(snap({ class: "org.omarchy.screensaver" }), s))
assert.ok(!M.canPark(snap({ workspace: "special:scratchpad" }), s))
assert.ok(!M.canPark(snap({ workspace: "special:desktop-undo" }), s))
assert.ok(!M.canPark(snap({ address: "" }), s))

let r = M.pushPark(s, snap())
assert.strictEqual(r.reason, "parked")
assert.strictEqual(r.state.undo.length, 1)
assert.strictEqual(r.state.undo[0].type, "park")
assert.deepStrictEqual(r.kills, [])

r = M.pushPark(r.state, snap({ address: "0x1", title: "One" }))
r = M.pushPark(r.state, snap({ address: "0x2", title: "Two" }))
r = M.pushPark(r.state, snap({ address: "0x3", title: "Three" }))
assert.strictEqual(r.state.undo.length, 3)
assert.deepStrictEqual(r.kills, ["0xabc"])
assert.strictEqual(r.state.undo[0].address, "0x1")

let u = M.undo(r.state)
assert.strictEqual(u.action.label, "Three")
assert.strictEqual(u.effects[0].type, "restore")
assert.strictEqual(u.effects[0].workspace, "2")
assert.strictEqual(u.state.undo.length, 2)
assert.strictEqual(u.state.redo.length, 1)

let red = M.redo(u.state)
assert.strictEqual(red.effects[0].type, "park")
assert.strictEqual(red.effects[0].workspace, M.PARK_WORKSPACE)
assert.strictEqual(red.state.undo.length, 3)
assert.strictEqual(red.state.redo.length, 0)

// New action clears redo
u = M.undo(red.state)
r = M.pushPark(u.state, snap({ address: "0x9", title: "Nine" }))
assert.strictEqual(r.state.redo.length, 0)

// Excluded close does not park
r = M.pushPark(M.createState(), snap({ class: "org.omarchy.lock" }))
assert.strictEqual(r.reason, "excluded")
assert.strictEqual(r.state.undo.length, 0)

// Relaunch recording
r = M.pushRelaunch(M.createState(), snap({ address: "0xdead" }))
assert.strictEqual(r.reason, "recorded")
u = M.undo(r.state)
assert.strictEqual(u.effects[0].type, "relaunch")
red = M.redo(u.state)
assert.deepStrictEqual(red.effects, [])

assert.deepStrictEqual(M.relaunchCommand(snap()), ["omarchy-launch-browser"])
assert.deepStrictEqual(
  M.relaunchCommand(snap({ class: "chrome-teams.cloud.microsoft__-Default", command: [] })),
  ["omarchy-launch-webapp", "https://teams.cloud.microsoft"]
)
assert.strictEqual(M.relaunchCommand(snap({ class: "steam_app_1", command: ["S:\\game.exe"] })), null)
assert.strictEqual(
  M.relaunchCommand(snap({ class: "Alacritty", command: ["/usr/bin/alacritty", "--token=secret"] })),
  null
)
assert.strictEqual(M.sanitizeLabel("a\nb\tc", 52), "abc")

s = M.createState()
r = M.pushPark(s, snap({ address: "0x1" }))
r = M.pushPark(r.state, snap({ address: "0x2" }))
s = M.dropAddress(r.state, "0x1")
assert.deepStrictEqual(M.parkedAddresses(s), ["0x2"])

const summary = M.statusSummary(s)
assert.strictEqual(summary.undo, 1)
assert.strictEqual(summary.parked, 1)

u = M.undo(M.createState())
assert.strictEqual(u.action, null)
assert.deepStrictEqual(u.effects, [])

assert.strictEqual(M.clampMax(99), 20)
assert.strictEqual(M.clampMax(0), 1)
assert.strictEqual(M.luaString('a"b'), 'a\\"b')

s = M.reset(r.state)
assert.strictEqual(s.undo.length, 0)
assert.strictEqual(s.redo.length, 0)
assert.strictEqual(s.max, r.state.max)

// Restore a middle parked window without bringing back the newer one.
s = M.createState()
s = M.pushPark(s, snap({ address: "0x1", title: "One" })).state
s = M.pushPark(s, snap({ address: "0x2", title: "Two" })).state
s = M.pushPark(s, snap({ address: "0x3", title: "Three" })).state
u = M.undoAt(s, 1, null) // Two
assert.strictEqual(u.action.address, "0x2")
assert.deepStrictEqual(u.state.undo.map(function (a) { return a.address }), ["0x1", "0x3"])
assert.strictEqual(u.effects[0].workspace, "2")
u = M.undoAt(s, 0, { workspace: "5" })
assert.strictEqual(u.effects[0].workspace, "5")
assert.strictEqual(u.effects[0].here, true)
assert.strictEqual(M.undoAt(s, 99, null).action, null)

s = M.attachMedia(s, "0x3", { muted: [4], paused: ["spotify"] })
assert.deepStrictEqual(s.undo[2].media, { muted: [4], paused: ["spotify"] })
assert.strictEqual(M.toastLabel({ title: "Inbox - Gmail - Google Chrome" }), "Inbox - Gmail - Google Chrome")
assert.ok(M.toastLabel({ title: "x".repeat(80) }).length <= 32)

console.log("UndoModel tests passed")
