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
    flightArrived() {}, mediaQueue: [], trackAppClose: false, strandedCount: 0, journalConsumed: true,
    journalDirty: false, pendingJournalText: "", journalBin: "reprieve-journal", stateDir: "/state", barAnchors: {}}
  const timer = {restart() {}, queue() {}}
  const Hyprland = {toplevels: {values: [handle]}, monitors: {values: [{id: 0, name: "DP-2", x: 0, y: 0, scale: 1}]},
    workspaces: {values: []}, focusedMonitor: null,
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
  const journalWriter = {running: false, payload: "", command: []}
  const context = vm.createContext({root, Model, Hyprland, console, Date, journalWriter,
    quarantineProcess: {running: false}, cacheDebounce: timer, refreshDebounce: timer, adoptTimer: timer,
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
  return {root, handle, jobs, dispatches, context, journalWriter}
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
function moves(dispatches) {
  return dispatches.filter(d => d.includes("window.move")).map(d => d.match(/workspace = "([^"]+)"/)[1])
}
test("a window closed during its park flight is never hidden later (address reuse)", () => {
  const {root, handle, jobs, dispatches, context} = service()
  root.parkWindow("0xabc")
  context.Hyprland.toplevels.values = []
  root.handleClose("abc")
  // Hyprland maps an unrelated window at the same address before the
  // overlay or watchdog reaches the old cut.
  const reused = {address: "0xabc", title: "New", workspace: {name: "3"}, lastIpcObject: {class: "foot", workspace: {name: "3"}}}
  context.Hyprland.toplevels.values = [reused]
  assert.equal(root.flightCut(jobs[0].token), "unknown")
  assert.deepEqual(moves(dispatches), [])
  assert.equal(Object.keys(root.pendingFlights).length, 0)
  assert.equal(handle.workspace.name, "2")
})
test("closing a parked window does not report it as stranded", () => {
  const {root, jobs, context} = service()
  root.parkWindow("0xabc"); root.flightCut(jobs[0].token)
  assert.equal(root.strandedCount, 0)
  context.Hyprland.toplevels.values = []
  root.handleClose("abc")
  assert.equal(root.strandedCount, 0)
  assert.equal(Model.findParked(root.model, "0xabc"), -1)
})
test("the journal is not replaced before the startup read is merged", () => {
  const {root, journalWriter} = service()
  root.session = "test-session"
  root.journalConsumed = false
  root.model = Model.pushPark(root.model, {address: "0xabc", class: "foot", title: "Probe", workspace: "2"}, 1).state
  root.persist(); root.flushJournal()
  assert.equal(journalWriter.running, false, "wrote a journal that lacks the unread entries")
  assert.equal(root.journalDirty, true)
  root.journalConsumed = true
  root.flushJournal()
  assert.equal(journalWriter.running, true)
  assert.equal(JSON.parse(journalWriter.payload).entries[0].address, "0xabc")
})
test("a window mapped at a reused address starts from a fresh snapshot", () => {
  const {root} = service()
  root.snapshots = {"0xabc": {address: "0xabc", workspace: "special:reprieve", workspaceKnown: true, floating: true, floatingKnown: true}}
  root.handleRawEvent("openwindow", "abc,3,foot,shell")
  assert.equal(root.snapshots["0xabc"].workspace, "3")
  assert.equal(root.snapshots["0xabc"].floatingKnown, undefined)
  assert.equal(root.snapshots["0xabc"].workspaceKnown, undefined)
})
test("redo parks the window where it is now, so undo returns it there", () => {
  const {root, handle, jobs, dispatches} = service()
  root.parkWindow("0xabc"); root.flightCut(jobs[0].token)
  root.undoLast()
  // The user moves the restored window to workspace 7.
  handle.workspace = {name: "7"}; handle.lastIpcObject.workspace = {name: "7"}
  root.handleMove("abc", "7"); root.patchSnapshot("abc", {workspace: "7", workspaceKnown: true})
  root.redoLast(); root.flightCut(jobs[jobs.length - 1].token)
  root.undoLast()
  assert.equal(moves(dispatches).pop(), "7")
})
test("a restore flight is skipped when the window returns on another screen", () => {
  for (const [monitor, flies] of [["HDMI-A-1", false], ["DP-2", true]]) {
    const {root, jobs, context} = service()
    root.flightHandler.remembered = () => ({rect: {x: 0, y: 0, w: 600, h: 400}, screen: "DP-2"})
    context.Hyprland.workspaces.values = [{name: "2", monitor: {name: monitor}}]
    root.parkWindow("0xabc"); root.flightCut(jobs[0].token)
    root.undoLast()
    assert.equal(jobs.filter(j => j.kind === "restore").length, flies ? 1 : 0, monitor)
  }
})
test("restoring here while a scratchpad is open uses the monitor's workspace", () => {
  const {root, context} = service()
  context.Hyprland.focusedWorkspace = {name: "special:magic"}
  context.Hyprland.focusedMonitor = {name: "DP-2", activeWorkspace: {name: "4"}}
  assert.equal(root.currentWorkspace(), "4")
})
test("re-publishing an unchanged bar anchor keeps the same object", () => {
  const {root} = service()
  root.setBarAnchor("DP-2", 10, 20, 22)
  const first = root.barAnchors
  root.setBarAnchor("DP-2", 10.2, 19.8, 22)
  assert.equal(root.barAnchors, first)
  root.setBarAnchor("DP-2", 40, 20, 22)
  assert.notEqual(root.barAnchors, first)
  assert.equal(root.barAnchors["DP-2"].x, 40)
})
if (failures) process.exit(1)
