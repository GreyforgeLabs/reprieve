#!/usr/bin/env node
"use strict"
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const Model = require("../ReprieveModel.js")
function service() {
  const handle = {address: "0xabc", title: "Probe", workspace: {name: "2"}, lastIpcObject: {class: "foot", workspace: {name: "2"}, at: [30, 50], size: [600, 400], monitor: 0, pid: 123}}
  const jobs = [], dispatches = []
  const root = {model: Model.createState(), snapshots: {}, expected: {}, pendingFlights: {}, flightSequence: 0,
    parkReadQueue: [], currentParkRead: "", parkWorkspace: Model.PARK_WORKSPACE, flight: "angel", session: "", showToast: false,
    parkTimeout: 0, pauseMediaOnPark: false, flightHandler: {remembered: () => null, wants: () => true},
    flightPark: job => jobs.push(job), flightRestore: job => jobs.push(job), windowParked() {},
    flightArrived() {}, mediaQueue: [], trackAppClose: false}
  const timer = {restart() {}, queue() {}}
  const Hyprland = {toplevels: {values: [handle]}, monitors: {values: [{id: 0, name: "DP-2", x: 0, y: 0, scale: 1}]},
    focusedWorkspace: {name: "2"}, activeToplevel: handle,
    dispatch(lua) {
      dispatches.push(lua)
      if (lua.includes("window.move")) {
        const ws = lua.match(/workspace = "([^"]+)"/)[1]
        handle.workspace = {name: ws}; handle.lastIpcObject.workspace = {name: ws}
        root.handleMove(handle.address, ws)
      }
    }}
  const parkGeometryReader = {command: []}
  Object.defineProperty(parkGeometryReader, "running", {get: () => false, set(value) {
    if (value) root.finishParkRead(root.currentParkRead, JSON.stringify([Object.assign({}, handle.lastIpcObject, {address: handle.address})]), 0)
  }})
  const context = vm.createContext({root, Model, Hyprland, console, Date,
    parkGeometryReader, flightWatchdog: timer, expectSweep: timer, persistDebounce: timer, animClear: timer,
    toastTimer: timer, mediaProcess: {running: false}, mediaTimeout: timer,
    Quickshell: {execDetached() {}}, Qt: {callLater() {}}})
  const source = fs.readFileSync(process.env.REPRIEVE_SERVICE_SOURCE || require.resolve("../Service.qml"), "utf8")
  for (const m of source.matchAll(/^  function (\w+)\([^\n]*\) \{\n[\s\S]*?^  \}/gm)) {
    vm.runInContext(m[0], context)
    root[m[1]] = context[m[1]]
  }
  const change = source.match(/  onParkTimeoutChanged: \{([\s\S]*?)\n  \}/)
  vm.runInContext("function timeoutChanged() {" + change[1] + "}", context)
  root.timeoutChanged = context.timeoutChanged
  context.parkTimeout = 5
  return {root, handle, jobs, dispatches, context}
}
let failures = 0
function test(name, fn) {try {fn(); console.log("PASS", name)} catch (e) {failures++; console.error("FAIL", name, e.message)}}
test("duplicate park during flight is idempotent", () => {
  const {root, jobs} = service()
  assert.equal(root.parkWindow("0xabc"), "parked")
  const sequence = root.model.sequence
  root.parkWindow("0xabc")
  assert.equal(jobs.length, 1)
  assert.equal(root.model.sequence, sequence)
})
test("undo before park cut cannot leave an untracked hidden window", () => {
  const {root, handle, jobs} = service()
  root.parkWindow("0xabc")
  root.undoLast()
  for (const job of jobs) root.flightCut(job.token)
  assert.equal(handle.workspace.name, "2")
  assert.equal(Model.findParked(root.model, "0xabc"), -1)
  assert.equal(Object.keys(root.pendingFlights).length, 0)
})
test("redo uses the configured park flight", () => {
  const {root, jobs} = service()
  root.parkWindow("0xabc"); root.flightCut(jobs[0].token)
  root.undoLast(); root.redoLast()
  assert.equal(jobs.length, 2)
  assert.equal(jobs[1].kind, "park")
})
test("park geometry uses the fresh compositor response", () => {
  const {root, handle} = service()
  const fresh = Object.assign({}, handle.lastIpcObject, {at: [400, 300], size: [600, 400]})
  const job = root.flightJob("park", handle, handle.address, fresh)
  assert.equal(job.rect.x, 400)
  assert.equal(job.rect.y, 300)
  assert.equal(job.rect.w, 600)
})
test("enabling a timeout persists the granted grace interval", () => {
  const {root} = service()
  root.model = Model.pushPark(root.model, {address: "0xabc", class: "foot", title: "Probe", workspace: "2"}, 1).state
  root.session = "test-session"
  root.parkTimeout = 5
  root.timeoutChanged()
  assert.ok(root.model.undo[0].parkedAt > 1)
  assert.ok(root.pendingJournalText, "grace timestamp was not journaled")
  assert.equal(JSON.parse(root.pendingJournalText).entries[0].parkedAt, root.model.undo[0].parkedAt)
})
test("setting the current value succeeds without an unnecessary write", () => {
  const {root} = service()
  root.settingsEntry = {id: "tech.greyforge.reprieve", flight: "angel"}
  root.pluginId = "tech.greyforge.reprieve"
  root.shell = {updateEntryInline: () => false}
  assert.equal(root.setSetting("flight", "angel"), "ok")
})
test("a rejected setting write keeps the last good local setting", () => {
  const {root} = service()
  root.settingsEntry = {id: "tech.greyforge.reprieve", flight: "angel"}
  root.pluginId = "tech.greyforge.reprieve"
  root.shell = {updateEntryInline: () => false}
  assert.equal(root.setSetting("flight", "subtle"), "could not write shell.json")
  assert.equal(root.settingsEntry.flight, "angel")
})
test("park uses the activated Wayland window when Hyprland focus is temporarily null", () => {
  const {root, handle, context} = service()
  context.Hyprland.activeToplevel = null
  handle.wayland = {activated: true}
  assert.equal(root.parkActive(), "parked")
  assert.equal(Model.findParked(root.model, handle.address), 0)
})
test("immediate re-park uses the restore workspace while IPC geometry lags", () => {
  const {root, context, jobs} = service()
  root.parkWindow("0xabc"); root.flightCut(jobs[0].token)
  // The raw move/our own dispatch precedes lastIpcObject and handle.workspace.
  context.Hyprland.dispatch = () => {}
  root.undoLast()
  assert.equal(root.parkWindow("0xabc"), "parked")
  assert.equal(root.model.undo[0].workspace, "2")
})
if (failures) process.exit(1)
