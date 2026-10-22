#!/usr/bin/env node
"use strict"
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const Model = require("../ReprieveModel.js")
function service(options = {}) {
  const handle = {address: "0xabc", title: "Probe", workspace: {name: "2"}, lastIpcObject: {class: "foot", workspace: {name: "2"}, floating: false, pinned: false, at: [30, 50], size: [600, 400], monitor: 0, pid: 123}}
  // A real clients response can differ from Quickshell's cached IPC object.
  const liveClient = options.liveClient ? Object.assign({}, handle.lastIpcObject, options.liveClient, {address: handle.address}) : null
  const jobs = [], dispatches = []
  const root = {model: Model.createState(), snapshots: {}, expected: {}, pendingFlights: {}, flightSequence: 0,
    parkReadQueue: [], currentParkRead: "", parkWorkspace: Model.PARK_WORKSPACE, flight: "angel", session: "", showToast: false,
    parkTimeout: 0, pauseMediaOnPark: false, flightHandler: {remembered: () => null, wants: () => true},
    flightPark: job => jobs.push(job), flightRestore: job => jobs.push(job), windowParked() {},
    flightArrived() {}, mediaQueue: [], trackAppClose: false, strandedCount: 0, journalConsumed: true,
    journalDirty: false, pendingJournalText: "", journalBin: "reprieve-journal", stateDir: "/state", barAnchors: {}}
  // Mirror the QML settings' fallback to the legacy shared flight value.
  for (const key of ["parkFlight", "restoreFlight"]) {
    let override
    Object.defineProperty(root, key, {get: () => override === undefined ? root.flight : override, set: value => { override = value }})
  }
  const timer = {restart() {}, queue() {}}
  const Hyprland = {toplevels: {values: [handle]}, monitors: {values: [{id: 0, name: "DP-2", x: 0, y: 0, scale: 1}]},
    workspaces: {values: []}, focusedMonitor: null,
    focusedWorkspace: {name: "2"}, activeToplevel: handle,
    dispatch(lua) {
      dispatches.push(lua)
      if (liveClient && lua.includes("window.pin")) {
        if (lua.includes("disable")) liveClient.pinned = false
        else if (liveClient.floating) liveClient.pinned = true
      }
      if (liveClient && lua.includes("window.float")) liveClient.floating = lua.includes("enable")
      if (lua.includes("window.move")) {
        if (liveClient && liveClient.pinned) return
        const ws = lua.match(/workspace = "([^"]+)"/)[1]
        if (liveClient) liveClient.workspace = {name: ws}
        handle.workspace = {name: ws}; handle.lastIpcObject.workspace = {name: ws}
        root.handleMove(handle.address, ws)
      }
    }}
  const parkGeometryReader = {command: []}
  let readerRunning = false
  function finishRead(text, code = 0) {
    const token = root.currentParkRead
    root.currentParkRead = ""
    readerRunning = false
    const clients = liveClient ? [liveClient] : [Object.assign({}, handle.lastIpcObject, {address: handle.address})]
    root.finishParkRead(token, text === undefined ? JSON.stringify(clients) : text, code)
    root.pumpParkReads()
  }
  Object.defineProperty(parkGeometryReader, "running", {get: () => readerRunning, set(value) {
    readerRunning = value
    if (value && !options.deferRead) finishRead()
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
  return {root, handle, jobs, dispatches, context, journalWriter, liveClient, finishRead}
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

test("bar accent accepts brand|theme|accent and persists it", () => {
  const {root} = service()
  root.settingsEntry = {id: "tech.greyforge.reprieve"}
  root.pluginId = "tech.greyforge.reprieve"
  root.shell = {updateEntryInline: () => true}
  assert.equal(root.setSetting("barAccent", "theme"), "ok")
  assert.equal(root.settingsEntry.barAccent, "theme")
  assert.equal(root.setSetting("barAccent", "THEME"), "ok")
  assert.equal(root.setSetting("barAccent", "accent"), "ok")
  assert.equal(root.settingsEntry.barAccent, "accent")
  assert.equal(root.setSetting("barAccent", "cyan"), "expected brand|theme|accent")
})

test("setting the current value succeeds without an unnecessary write", () => {
  const {root} = service()
  root.settingsEntry = {id: "tech.greyforge.reprieve", flight: "angel", parkFlight: "angel", restoreFlight: "angel"}
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
test("parking a pinned window unpins before the move and restore re-pins after floating", () => {
  const {root, handle, jobs, dispatches} = service()
  handle.lastIpcObject.pinned = true
  handle.lastIpcObject.floating = true
  root.parkWindow("0xabc")
  root.flightCut(jobs[0].token)
  const pinOff = dispatches.findIndex(d => d.includes("window.pin") && d.includes("disable"))
  const move = dispatches.findIndex(d => d.includes("window.move"))
  assert.ok(pinOff >= 0, "park must unpin a pinned window")
  assert.ok(pinOff < move, "the unpin must precede the move to the park workspace")
  root.undoLast()
  const floatOn = dispatches.findIndex(d => d.includes("window.float") && d.includes("enable"))
  const pinOn = dispatches.findIndex(d => d.includes("window.pin") && d.includes("enable"))
  assert.ok(pinOn > floatOn && floatOn > move, "the re-pin must follow the float restore (pin requires a floating window)")
})
test("parking with flight off still runs the geometry read before the cut", () => {
  const {root, handle, dispatches} = service()
  root.flight = "off"
  handle.lastIpcObject.pinned = true
  handle.lastIpcObject.floating = true
  root.parkWindow("0xabc")
  const pinOff = dispatches.findIndex(d => d.includes("window.pin") && d.includes("disable"))
  const move = dispatches.findIndex(d => d.includes("window.move"))
  assert.ok(pinOff >= 0 && pinOff < move, "the read-gated cut must still unpin with flight off")
})
test("early restores cancel an unread park without changing live pin state", () => {
  for (const restore of [s => s.root.undoLast(), s => s.root.restoreAt(0, true),
    s => s.root.restoreAddress("0xabc", false), s => s.root.restoreBySequence(s.root.model.undo[0].sequence, false),
    s => s.root.restoreAll(), s => s.root.resetAll()]) {
    const s = service({deferRead: true, liveClient: {floating: true, pinned: false}})
    s.root.flight = "off"
    s.root.session = "test-session"
    s.handle.lastIpcObject.pinned = true
    s.handle.lastIpcObject.floating = true
    s.root.parkWindow("0xabc")
    assert.equal(s.dispatches.length, 0)
    restore(s)
    s.finishRead()
    assert.equal(s.liveClient.pinned, false, "the stale cache must not re-pin a window that never moved")
    assert.equal(s.liveClient.workspace.name, "2")
    assert.equal(s.dispatches.length, 0, "an unread park has no real-window effects to undo")
    assert.equal(Model.findParked(s.root.model, "0xabc"), -1)
    assert.equal(Object.keys(s.root.pendingFlights).length, 0)
    assert.equal(JSON.parse(s.root.pendingJournalText).entries.length, 0)
  }
})
test("fresh pin state controls deferred park, journal and restore in every flight mode", () => {
  for (const mode of ["off", "subtle", "angel"]) {
    const s = service({deferRead: true, liveClient: {floating: true, pinned: true}})
    s.root.flight = mode
    s.root.session = "test-session"
    s.handle.lastIpcObject.floating = true
    s.root.parkWindow("0xabc")
    assert.equal(s.dispatches.length, 0)
    s.finishRead()
    for (const job of s.jobs) s.root.flightCut(job.token)
    assert.equal(s.liveClient.workspace.name, Model.PARK_WORKSPACE)
    assert.equal(s.liveClient.pinned, false)
    assert.equal(JSON.parse(s.root.pendingJournalText).entries[0].pinned, true)
    s.root.undoLast()
    assert.equal(s.liveClient.workspace.name, "2")
    assert.equal(s.liveClient.pinned, true)
  }
})
test("failed or unusable geometry reads leave the window and journal unparked", () => {
  for (const [text, code] of [["", 1], ["", 15], ["{broken", 0], ["null", 0], ["{}", 0], ["[]", 0],
    [JSON.stringify([null, {address: "0xabc"}]), 0]]) {
    const s = service({deferRead: true, liveClient: {floating: true, pinned: true}})
    s.root.flight = "off"
    s.root.session = "test-session"
    s.root.parkWindow("0xabc")
    s.finishRead(text, code)
    assert.equal(s.dispatches.length, 0, "unknown pin state must never reach the cut")
    assert.equal(s.liveClient.workspace.name, "2")
    assert.equal(s.liveClient.pinned, true)
    assert.equal(Model.findParked(s.root.model, "0xabc"), -1)
    assert.equal(JSON.parse(s.root.pendingJournalText).entries.length, 0)
    assert.equal(Object.keys(s.root.pendingFlights).length, 0)
    assert.equal(s.root.lastResult, "park failed")
  }
})
test("a watchdog cut cannot park from an unread pin snapshot", () => {
  const s = service({deferRead: true, liveClient: {floating: true, pinned: true}})
  s.root.parkWindow("0xabc")
  const token = Object.keys(s.root.pendingFlights)[0]
  s.root.flightCut(token)
  s.finishRead()
  assert.equal(s.dispatches.length, 0)
  assert.equal(Model.findParked(s.root.model, "0xabc"), -1)
  assert.equal(s.liveClient.workspace.name, "2")
})
test("an old read after early undo cannot corrupt a new park of the same window", () => {
  const s = service({deferRead: true, liveClient: {floating: true, pinned: true}})
  s.root.flight = "off"
  s.handle.lastIpcObject.floating = true
  s.root.parkWindow("0xabc")
  s.root.undoLast()
  s.root.parkWindow("0xabc")
  const sequence = s.root.model.undo[0].sequence
  s.finishRead("", 1)
  assert.equal(s.root.model.undo[0].sequence, sequence)
  assert.equal(s.dispatches.length, 0)
  s.finishRead()
  assert.equal(s.liveClient.workspace.name, Model.PARK_WORKSPACE)
  assert.equal(s.root.model.undo[0].pinned, true)
  s.root.undoLast()
  assert.equal(s.liveClient.pinned, true)
})
test("removal and restoration modes are independent in all nine combinations", () => {
  for (const park of ["off", "subtle", "angel"]) for (const restore of ["off", "subtle", "angel"]) {
    const s = service()
    s.root.parkFlight = park
    s.root.restoreFlight = restore
    s.root.parkWindow("0xabc")
    const capture = park !== "off" || restore !== "off"
    assert.equal(s.jobs.length, capture ? 1 : 0, park + "/" + restore)
    if (capture) {
      assert.equal(s.jobs[0].kind, "park")
      assert.equal(s.jobs[0].mode, park, "Off removal must capture without a visible flight")
      s.root.flightCut(s.jobs[0].token)
      s.root.flightHandler.remembered = () => ({rect: {x: 30, y: 50, w: 600, h: 400}, screen: "DP-2"})
    }
    s.root.undoLast()
    const restoreJob = s.jobs.find(job => job.kind === "restore")
    assert.equal(!!restoreJob, restore !== "off", park + "/" + restore)
    if (restoreJob) {
      assert.equal(restoreJob.mode, restore)
      s.root.flightCut(restoreJob.token)
    }
    assert.equal(s.handle.workspace.name, "2")
    assert.equal(Object.keys(s.root.pendingFlights).length, 0)
  }
})
test("early undo cancels a capture-only park before its fresh read", () => {
  const s = service({deferRead: true, liveClient: {floating: true, pinned: true}})
  s.root.parkFlight = "off"
  s.root.restoreFlight = "angel"
  s.root.parkWindow("0xabc")
  s.root.undoLast()
  s.finishRead()
  assert.equal(s.dispatches.length, 0)
  assert.equal(s.jobs.length, 0)
  assert.equal(s.liveClient.pinned, true)
})
test("both animation settings persist through the existing settings API", () => {
  const s = service()
  s.root.settingsEntry = {id: "tech.greyforge.reprieve", flight: "subtle"}
  s.root.pluginId = "tech.greyforge.reprieve"
  s.root.shell = {updateEntryInline: () => true}
  assert.equal(s.root.setSetting("parkFlight", "off"), "ok")
  assert.equal(s.root.setSetting("restoreFlight", "angel"), "ok")
  assert.equal(s.root.settingsEntry.parkFlight, "off")
  assert.equal(s.root.settingsEntry.restoreFlight, "angel")
  assert.equal(s.root.settingsEntry.flight, "subtle")
  assert.equal(s.root.setSetting("restoreFlight", "invalid"), "expected off|subtle|angel")
})
test("the legacy shared setting resets both directions even when its value is unchanged", () => {
  const s = service()
  s.root.settingsEntry = {id: "tech.greyforge.reprieve", flight: "subtle", parkFlight: "off", restoreFlight: "angel"}
  s.root.pluginId = "tech.greyforge.reprieve"
  let writes = 0
  s.root.shell = {updateEntryInline: () => { writes++; return true }}
  assert.equal(s.root.setSetting("flight", "subtle"), "ok")
  assert.equal(s.root.settingsEntry.parkFlight, "subtle")
  assert.equal(s.root.settingsEntry.restoreFlight, "subtle")
  assert.equal(writes, 1)
})
if (failures) process.exit(1)
