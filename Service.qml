import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "ReprieveModel.js" as Model

// Reprieve service: parks Super+W closes onto a hidden special workspace
// instead of killing the process, and remembers enough to bring them back
// after the shell restarts. Never listens to key events and never binds
// Ctrl+Z.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : Model.PLUGIN_ID
  // Omarchy strips __sourceDir from third-party manifests; fall back to the
  // directory this file was loaded from.
  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    return url.replace(/\/+$/, "")
  }
  readonly property string mediaBin: pluginDir + "/bin/reprieve-media"
  readonly property string journalBin: pluginDir + "/bin/reprieve-journal"
  readonly property string bindsBin: pluginDir + "/bin/reprieve-binds"
  readonly property string parkWorkspace: Model.PARK_WORKSPACE
  readonly property int maxStack: Model.clampMax(setting("maxStack", Model.DEFAULT_MAX))
  readonly property bool trackAppClose: setting("trackAppClose", true) !== false
  readonly property bool pauseMediaOnPark: setting("pauseMediaOnPark", true) !== false
  readonly property bool showToast: setting("showToast", true) !== false
  readonly property bool setupDismissed: setting("setupDismissed", false) === true
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string stateDir: stateHome + "/reprieve"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string shellConfigPath: configHome + "/omarchy/shell.json"
  // Our plugins[] entry from shell.json. The third-party shell API exposes
  // no read surface for it, so it is read (never written) from disk.
  property var settingsEntry: ({})
  readonly property string session: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

  property var model: Model.createState({ max: maxStack })
  property var snapshots: ({})
  property var expected: ({})
  property var undoStack: []
  property var redoStack: []
  property int undoCount: 0
  property int redoCount: 0
  property int parkedCount: 0
  property string lastLabel: ""
  property string lastResult: ""
  property string recoveryNotice: ""
  property bool toastOpen: false
  property string toastText: ""

  // Journal lifecycle
  property string journalStatus: "loading"
  property var journalEntries: []
  property int journalSequence: 0
  property bool journalConsumed: false
  property bool journalDirty: false
  property string pendingJournalText: ""
  property double startedAt: Date.now()

  // Bindings / setup
  property var bindsStatus: null
  property var lastInstallResult: null
  property bool setupOffered: false

  // Media
  property var mediaQueue: []
  property string mediaJobKind: ""
  property string mediaJobAddress: ""

  readonly property bool bindsInstalled: !!(bindsStatus && bindsStatus.installed)
  readonly property bool legacyDetected: !!(bindsStatus && bindsStatus.legacy && bindsStatus.legacy.length)

  onMaxStackChanged: {
    if (!root.model) return
    var next = Model.cloneState(root.model)
    next.max = maxStack
    root.model = next
    root.publish()
  }

  // ---------------------------------------------------------------- settings

  function reloadSettings() {
    var found = {}
    try {
      var cfg = JSON.parse(String(shellConfigFile.text() || "{}").slice(0, 1048576) || "{}")
      var plugins = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < plugins.length; i++) {
        var entry = plugins[i]
        if (entry && entry.id === root.pluginId) {
          for (var k in entry) found[k] = entry[k]
          break
        }
      }
    } catch (e) {}
    root.settingsEntry = found
  }

  function pluginEntry() {
    var entry = { id: root.pluginId }
    for (var k in root.settingsEntry) entry[k] = root.settingsEntry[k]
    return entry
  }

  function setting(name, fallback) {
    var entry = root.settingsEntry
    if (entry && entry[name] !== undefined && entry[name] !== null) return entry[name]
    return fallback
  }

  function saveSetting(name, value) {
    try {
      if (!root.shell || typeof root.shell.updateEntryInline !== "function") return false
      var next = root.pluginEntry()
      next[name] = value
      // Reflect immediately; the shell.json watcher confirms shortly after.
      var local = {}
      for (var k in next) local[k] = next[k]
      root.settingsEntry = local
      return root.shell.updateEntryInline(root.pluginId, next) !== false
    } catch (e) {
      console.warn("reprieve: saveSetting failed", e)
      return false
    }
  }

  function setShowToast(value) {
    var on = value !== false
    root.saveSetting("showToast", on)
    if (on) root.toast("Toasts on")
    else { root.toastOpen = false; root.toastText = "" }
  }

  function toggleShowToast() { root.setShowToast(!root.showToast) }

  function dismissSetup() { root.saveSetting("setupDismissed", true) }

  // ---------------------------------------------------------------- publish

  function publish() {
    root.undoStack = (root.model && root.model.undo) ? root.model.undo.slice() : []
    root.redoStack = (root.model && root.model.redo) ? root.model.redo.slice() : []
    var summary = Model.statusSummary(root.model)
    root.undoCount = summary.undo
    root.redoCount = summary.redo
    root.parkedCount = summary.parked
    root.lastLabel = summary.last
  }

  function commit(state) {
    root.model = state
    root.publish()
    root.persist()
  }

  function toast(message) {
    var text = String(message || "")
    if (!text || !root.showToast) return
    root.toastText = text
    root.toastOpen = true
    toastTimer.restart()
  }

  // ---------------------------------------------------------------- journal

  function persist() {
    if (!root.session) return
    root.pendingJournalText = JSON.stringify(Model.toJournal(root.model, root.session))
    root.journalDirty = true
    persistDebounce.restart()
  }

  function flushJournal() {
    if (!root.journalDirty || journalWriter.running) return
    // Never race a quarantine rename with a fresh write.
    if (quarantineProcess.running) { persistDebounce.restart(); return }
    root.journalDirty = false
    journalWriter.payload = root.pendingJournalText
    journalWriter.command = ["python3", root.journalBin, "write", "--state-dir", root.stateDir]
    journalWriter.running = true
  }

  function readJournal() {
    if (journalReader.running) return
    journalReader.command = ["python3", root.journalBin, "read", "--state-dir", root.stateDir]
    journalReader.running = true
  }

  function onJournalRead(text) {
    var envelope = null
    try { envelope = JSON.parse(String(text || "").slice(0, Model.JOURNAL_MAX_BYTES + 4096)) } catch (e) {}
    var status = envelope && envelope.status ? String(envelope.status) : "error"
    if (status === "ok") {
      var parsed = Model.parseJournal(envelope.text, root.session)
      root.journalStatus = parsed.status
      root.journalEntries = parsed.entries
      root.journalSequence = parsed.sequence
      if (parsed.status === "invalid") root.quarantineJournal(parsed.reason || "invalid")
      else if (parsed.status === "stale") root.quarantineJournal("stale")
    } else if (status === "empty") {
      root.journalStatus = "empty"
    } else {
      // symlink / irregular / oversized / unreadable: never trust it.
      root.journalStatus = status
      root.quarantineJournal(status)
    }
    root.scheduleReconcile()
  }

  function quarantineJournal(reason) {
    console.warn("reprieve: quarantining recovery journal:", reason)
    quarantineProcess.command = ["python3", root.journalBin, "quarantine", "--state-dir", root.stateDir, "--reason", String(reason || "damaged").replace(/[^A-Za-z0-9_-]/g, "")]
    quarantineProcess.running = true
  }

  // ------------------------------------------------------------ reconcile

  function toplevelsReady() {
    try {
      var list = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
      if (list.length === 0) return (Date.now() - root.startedAt) > 4000
      for (var i = 0; i < list.length; i++) {
        var ipc = list[i] && list[i].lastIpcObject
        if (ipc && ipc.class !== undefined) return true
      }
    } catch (e) {}
    return (Date.now() - root.startedAt) > 4000
  }

  function scheduleReconcile() {
    reconcileTimer.restart()
  }

  function liveWindows() {
    var out = []
    try {
      var list = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
      for (var i = 0; i < list.length; i++) {
        var snap = root.snapshotFromHandle(list[i])
        if (snap && snap.address) out.push(snap)
      }
    } catch (e) {}
    return out
  }

  function reconcile() {
    if (!root.toplevelsReady()) {
      reconcileTimer.interval = 700
      reconcileTimer.restart()
      return
    }
    var entries = root.journalConsumed ? [] : root.journalEntries
    var result = Model.reconcile(root.model, entries, root.liveWindows(), root.journalSequence)
    root.journalConsumed = true
    root.journalEntries = []
    var report = result.report
    root.commit(result.state)
    if (report.recovered.length) {
      var n = report.recovered.length
      root.recoveryNotice = "Recovered " + n + " parked window" + (n === 1 ? "" : "s") + " after shell reload."
      root.toast(root.recoveryNotice + " Super+Shift+Z to review")
      noticeTimer.restart()
    } else if (report.kept.length) {
      root.recoveryNotice = "Restored " + report.kept.length + " parked window" + (report.kept.length === 1 ? "" : "s") + " to the timeline."
      noticeTimer.restart()
    }
    if (report.converted.length || report.dropped.length)
      console.log("reprieve: reconcile converted", report.converted.length, "dropped", report.dropped.length)
    root.lastResult = "reconciled"
    return report
  }

  // ------------------------------------------------------------- expected

  function expect(address, kind) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    var next = {}
    for (var k in root.expected) next[k] = root.expected[k]
    var slot = next[addr] ? Object.assign({}, next[addr]) : { close: 0, move: 0 }
    slot[kind] = (slot[kind] || 0) + 1
    slot.at = Date.now()
    next[addr] = slot
    root.expected = next
    expectSweep.restart()
  }

  function consume(address, kind) {
    var addr = Model.normalizeAddress(address)
    var slot = addr ? root.expected[addr] : null
    if (!slot || !(slot[kind] > 0)) return false
    var next = {}
    for (var k in root.expected) next[k] = root.expected[k]
    var copy = Object.assign({}, slot)
    copy[kind] -= 1
    if (copy.close <= 0 && copy.move <= 0) delete next[addr]
    else next[addr] = copy
    root.expected = next
    return true
  }

  function sweepExpected() {
    var now = Date.now()
    var next = {}
    var changed = false
    for (var addr in root.expected) {
      var slot = root.expected[addr]
      if (slot && now - slot.at < 5000) { next[addr] = slot; continue }
      changed = true
      // An expected close that never came: the app refused to die (unsaved
      // changes prompt, say). If it is still parked, keep it recoverable.
      if (slot && slot.close > 0) root.adoptIfStranded(addr)
    }
    if (changed) root.expected = next
    if (Object.keys(next).length) expectSweep.restart()
  }

  function adoptIfStranded(address) {
    var handle = root.liveHandle(address)
    if (!handle) return
    var snap = root.snapshotFromHandle(handle)
    if (!snap || snap.workspace !== root.parkWorkspace) return
    if (Model.findParked(root.model, snap.address) !== -1) return
    snap.recovered = true
    snap.workspace = ""
    var result = Model.pushRecovered(root.model, snap)
    if (result.action) {
      root.commit(result.state)
      root.toast("Kept " + Model.toastLabel(result.action) + " recoverable")
    }
  }

  // ------------------------------------------------------------- hyprland

  function currentWorkspace() {
    try {
      var name = root.workspaceName(Hyprland.focusedWorkspace)
      if (name && !Model.isSpecialWorkspace(name)) return Model.normalizeWorkspace(name)
    } catch (e) {}
    return ""
  }

  // Omarchy 4 / Hyprland 0.56 is Lua-config only; there is no legacy path.
  function hyprDispatch(lua) {
    try {
      Hyprland.dispatch(lua)
    } catch (e) {
      console.warn("reprieve: dispatch failed", e)
    }
  }

  function windowSel(addr) {
    return 'window = "address:' + addr + '"'
  }

  // Omarchy's windowsIn/Out use popin — set no_anim before the move so park
  // and restore are a cut, not a cartoon.
  function setNoAnim(address, on) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    var value = on ? "1" : "0"
    root.hyprDispatch(
      'hl.dsp.window.set_prop({ ' + root.windowSel(addr) + ', prop = "no_anim", value = "' + value + '" })')
  }

  function moveSilent(address, workspace) {
    var addr = Model.normalizeAddress(address)
    var ws = Model.normalizeWorkspace(workspace)
    if (!addr || !ws) return false
    root.expect(addr, "move")
    root.setNoAnim(addr, true)
    root.hyprDispatch(
      'hl.dsp.window.move({ ' + root.windowSel(addr) + ', workspace = "' + ws + '", follow = false })')
    return true
  }

  // Hyprland 0.56's window.float parses "enable"/"disable"/"toggle"; any
  // other word (including "set") silently means toggle.
  function setFloating(address, floating) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    root.hyprDispatch(
      'hl.dsp.window.float({ ' + root.windowSel(addr) + ', action = "' + (floating ? "enable" : "disable") + '" })')
  }

  function setFullscreen(address, internal, client) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    var i = Math.max(0, Math.min(2, Math.floor(Number(internal) || 0)))
    var c = Math.max(0, Math.min(2, Math.floor(Number(client) || 0)))
    root.hyprDispatch(
      'hl.dsp.window.fullscreen_state({ ' + root.windowSel(addr) + ', internal = ' + i + ', client = ' + c + ', action = "set" })')
  }

  function focusWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    root.hyprDispatch('hl.dsp.focus({ ' + root.windowSel(addr) + ' })')
  }

  function closeWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    root.expect(addr, "close")
    root.setNoAnim(addr, true)
    root.hyprDispatch('hl.dsp.window.close({ ' + root.windowSel(addr) + ' })')
  }

  function liveHandle(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr || !Hyprland.toplevels) return null
    try {
      var list = Hyprland.toplevels.values || []
      for (var i = 0; i < list.length; i++) {
        var handle = list[i]
        if (handle && Model.normalizeAddress(handle.address) === addr) return handle
      }
    } catch (e) {}
    return null
  }

  function workspaceName(workspace) {
    if (!workspace) return ""
    var name = String(workspace.name || "")
    return name !== "" ? name : String(workspace.id || "")
  }

  function snapshotFromHandle(handle) {
    if (!handle) return null
    var address = Model.normalizeAddress(handle.address)
    if (!address) return null
    var cached = root.snapshots[address] || {}
    var ipc = handle.lastIpcObject || {}
    var ipcWs = ipc.workspace && ipc.workspace.name !== undefined ? String(ipc.workspace.name) : ""
    return {
      address: address,
      class: String(ipc.class || cached.class || ""),
      title: String(handle.title || ipc.title || cached.title || ""),
      workspace: root.workspaceName(handle.workspace) || ipcWs || cached.workspace || "",
      floating: cached.floatingKnown ? !!cached.floating : (ipc.floating !== undefined ? !!ipc.floating : !!cached.floating),
      fullscreen: Number(ipc.fullscreen !== undefined ? ipc.fullscreen : (cached.fullscreen || 0)),
      fullscreenClient: Number(ipc.fullscreenClient !== undefined ? ipc.fullscreenClient : (cached.fullscreenClient || 0)),
      pid: Number(ipc.pid || cached.pid || 0),
      openedAt: cached.openedAt || 0
    }
  }

  function activeSnapshot() {
    var handle = null
    try { handle = Hyprland.activeToplevel } catch (e) {}
    return handle ? root.snapshotFromHandle(handle) : null
  }

  function cacheToplevels() {
    var next = {}
    try {
      var list = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
      for (var i = 0; i < list.length; i++) {
        var snap = root.snapshotFromHandle(list[i])
        if (!snap || !snap.address) continue
        var previous = root.snapshots[snap.address]
        if (previous && previous.openedAt) snap.openedAt = previous.openedAt
        // changefloatingmode events keep the cache current between IPC
        // refreshes; snapshotFromHandle already preferred that value.
        if (previous && previous.floatingKnown) snap.floatingKnown = true
        next[snap.address] = snap
      }
    } catch (e) {}
    root.snapshots = next
  }

  function patchSnapshot(address, patch) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    var next = {}
    for (var key in root.snapshots) next[key] = root.snapshots[key]
    var existing = next[addr] ? Object.assign({}, next[addr]) : { address: addr }
    for (var p in patch) existing[p] = patch[p]
    next[addr] = existing
    root.snapshots = next
  }

  // ---------------------------------------------------------------- media

  function enqueueMedia(kind, args, address) {
    root.mediaQueue = root.mediaQueue.concat([{ kind: kind, args: args, address: address || "" }])
    root.pumpMedia()
  }

  function pumpMedia() {
    while (!mediaProcess.running && root.mediaQueue.length > 0) {
      var job = root.mediaQueue[0]
      root.mediaQueue = root.mediaQueue.slice(1)
      if (job.kind === "close") {
        // Queued behind the resume job so the stream is unmuted before it dies.
        root.closeWindow(job.address)
        continue
      }
      root.mediaJobKind = job.kind
      root.mediaJobAddress = job.address
      mediaProcess.command = job.args
      mediaProcess.running = true
    }
  }

  // Close a window Reprieve may have muted: unmute first, then close.
  function closeAfterMedia(address, media) {
    var clean = Model.sanitizeMedia(media)
    if (!clean || !root.pauseMediaOnPark) { root.closeWindow(address); return }
    root.requestResume(clean)
    root.mediaQueue = root.mediaQueue.concat([{ kind: "close", address: Model.normalizeAddress(address) }])
    root.pumpMedia()
  }

  function stopMedia() {
    mediaTimeout.stop()
    try { if (mediaProcess.running) mediaProcess.running = false } catch (e) {}
    root.mediaQueue = []
    root.mediaJobKind = ""
    root.mediaJobAddress = ""
  }

  function requestPause(snapshot) {
    if (!root.pauseMediaOnPark || !snapshot) return
    var pid = Number(snapshot.pid || 0)
    var klass = Model.sanitizeClass(snapshot.class)
    if (!pid && !klass) return
    root.enqueueMedia("pause", [
      "python3", root.mediaBin, "pause",
      "--pid", String(pid),
      "--class-name", klass
    ], snapshot.address)
  }

  function requestResume(media) {
    var clean = Model.sanitizeMedia(media)
    if (!clean) return
    root.enqueueMedia("resume", [
      "python3", root.mediaBin, "resume",
      "--payload", JSON.stringify(clean)
    ], "")
  }

  // -------------------------------------------------------------- effects

  // Before Reprieve closes a window it muted, unmute it: PipeWire's
  // stream-restore remembers mute per application, so a stream that dies
  // muted would come back muted the next time that app plays.
  function mediaFor(state, address) {
    var index = Model.findParked(state, address)
    if (index === -1) return null
    var action = state.undo[index]
    return action ? action.media : null
  }

  function applyKills(addresses, previousState) {
    for (var i = 0; i < (addresses || []).length; i++) {
      if (!root.liveHandle(addresses[i])) continue
      root.closeAfterMedia(addresses[i], previousState ? root.mediaFor(previousState, addresses[i]) : null)
    }
  }

  function applyEffects(effects, opts) {
    opts = opts || {}
    for (var i = 0; i < (effects || []).length; i++) {
      var effect = effects[i]
      if (!effect) continue
      if (effect.type === "park") {
        if (!root.liveHandle(effect.address)) continue
        root.moveSilent(effect.address, effect.workspace)
        root.requestPause({ address: effect.address, pid: effect.pid, class: effect.class })
      } else if (effect.type === "restore") {
        root.restoreWindow(effect, opts.focus !== false)
      } else if (effect.type === "relaunch") {
        root.relaunch(effect)
      } else if (effect.type === "close") {
        if (!root.liveHandle(effect.address)) continue
        root.closeWindow(effect.address)
      }
    }
  }

  function restoreWindow(effect, focus) {
    if (!root.liveHandle(effect.address)) {
      root.relaunch(effect)
      return false
    }
    var workspace = Model.normalizeWorkspace(effect.workspace)
    if (!workspace || Model.isSpecialWorkspace(workspace)) workspace = root.currentWorkspace()
    if (!workspace) workspace = "1"
    root.moveSilent(effect.address, workspace)
    root.setFloating(effect.address, !!effect.floating)
    if (effect.fullscreen > 0 || effect.fullscreenClient > 0)
      root.setFullscreen(effect.address, effect.fullscreen, effect.fullscreenClient)
    if (focus) root.focusWindow(effect.address)
    animClear.queue(effect.address)
    root.requestResume(effect.media)
    return true
  }

  function relaunch(effect) {
    var command = Model.relaunchCommand(effect)
    if (!command || !command.length) {
      root.lastResult = "gone"
      root.toast("Cannot restore " + Model.toastLabel(effect) + " — window is gone")
      return
    }
    try {
      Quickshell.execDetached(command)
      root.lastResult = "relaunched"
    } catch (e) {
      console.warn("reprieve: relaunch failed", e)
      root.lastResult = "error"
    }
  }

  // -------------------------------------------------------------- actions

  function parkActive() {
    var handle = null
    try { handle = Hyprland.activeToplevel } catch (e) {}
    if (!handle) { root.lastResult = "empty"; return "empty" }
    return root.parkWindow(handle.address)
  }

  // Park a specific window by address (IPC only; used by tests and tools).
  function parkWindow(address) {
    var handle = root.liveHandle(address)
    if (!handle) { root.lastResult = "empty"; return "empty" }
    var snapshot = root.snapshotFromHandle(handle)
    var previous = root.model
    var result = Model.pushPark(previous, snapshot)
    if (result.reason !== "parked") { root.lastResult = "passthrough"; return "passthrough" }
    root.commit(result.state)
    if (snapshot.fullscreen > 0) root.setFullscreen(snapshot.address, 0, 0)
    root.moveSilent(snapshot.address, root.parkWorkspace)
    root.applyKills(result.kills, previous)
    root.requestPause(snapshot)
    root.lastResult = "parked"
    root.toast("Parked " + Model.toastLabel(result.action) + " — Super+Z to undo")
    return "parked"
  }

  function closeActive() {
    var snapshot = root.activeSnapshot()
    if (!snapshot || !snapshot.address) {
      root.lastResult = "empty"
      return "empty"
    }
    root.closeWindow(snapshot.address)
    root.lastResult = "closed"
    return "closed"
  }

  // Permanent close of a parked window, from the timeline.
  function closeParked(address) {
    var index = Model.findParked(root.model, address)
    if (index === -1) {
      root.lastResult = "empty"
      return "empty"
    }
    var action = root.model.undo[index]
    root.commit(Model.dropAddress(root.model, action.address))
    root.closeAfterMedia(action.address, action.media)
    root.lastResult = "closed"
    root.toast("Closed " + Model.toastLabel(action))
    return "closed"
  }

  function undoLast() {
    var result = Model.undoAt(root.model, (root.model.undo || []).length - 1, { workspace: "" })
    return root.finishRestore(result, false)
  }

  function restoreAt(index, here) {
    var opts = { workspace: here === true ? root.currentWorkspace() : "" }
    var result = Model.undoAt(root.model, Number(index), opts)
    return root.finishRestore(result, here === true)
  }

  function finishRestore(result, here) {
    if (!result.action) {
      root.lastResult = "empty"
      return "empty"
    }
    var effects = result.effects
    // A recovered window has no recorded workspace: land it where the user is.
    if (effects.length && effects[0].type === "restore" && !effects[0].workspace)
      effects[0] = Object.assign({}, effects[0], { workspace: root.currentWorkspace(), here: true })
    root.commit(result.state)
    root.applyEffects(effects, { focus: true })
    var wasHere = !!(effects.length && effects[0].here)
    root.lastResult = wasHere ? "here" : "undone"
    root.toast((wasHere ? "Restored here: " : "Restored ") + Model.toastLabel(result.action))
    return root.lastResult
  }

  function redoLast() {
    var previous = root.model
    var result = Model.redo(previous)
    if (!result.action) {
      root.lastResult = "empty"
      return "empty"
    }
    root.commit(result.state)
    var effects = []
    for (var i = 0; i < result.effects.length; i++) {
      if (result.effects[i].type === "close") root.applyKills([result.effects[i].address], previous)
      else effects.push(result.effects[i])
    }
    root.applyEffects(effects)
    root.lastResult = "redone"
    root.toast("Parked " + Model.toastLabel(result.action) + " — Super+Z to undo")
    return "redone"
  }

  function restoreAll() {
    var result = Model.restoreAll(root.model, root.currentWorkspace())
    if (!result.actions.length) {
      root.lastResult = "empty"
      return "empty"
    }
    root.commit(result.state)
    root.applyEffects(result.effects, { focus: false })
    root.lastResult = "restored " + result.actions.length
    root.toast("Restored " + result.actions.length + " parked window" + (result.actions.length === 1 ? "" : "s"))
    return root.lastResult
  }

  function clearHistory() {
    var result = Model.clear(root.model)
    if (!result.ok) {
      root.lastResult = "refused"
      return "Reprieve: " + result.live + " live parked window" + (result.live === 1 ? "" : "s") + " remain.\nRestore or permanently close them before clearing recovery state."
    }
    root.commit(result.state)
    root.lastResult = "cleared"
    return "cleared"
  }

  function resetAll() {
    var result = Model.reset(root.model, root.currentWorkspace())
    root.commit(result.state)
    root.applyEffects(result.effects, { focus: false })
    root.recoveryNotice = ""
    root.lastResult = "reset " + result.actions.length
    if (result.actions.length) root.toast("Restored " + result.actions.length + " and reset")
    return root.lastResult
  }

  // --------------------------------------------------------------- events

  function handleClose(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    if (root.consume(addr, "close")) {
      if (Model.findParked(root.model, addr) !== -1) root.commit(Model.dropAddress(root.model, addr))
      return
    }
    if (Model.findParked(root.model, addr) !== -1) {
      var dead = Model.markDead(root.model, addr)
      root.commit(dead.state)
      if (dead.converted) root.toast(Model.toastLabel(dead.action) + " closed while parked — Reopen available")
      else if (dead.action) root.toast(Model.toastLabel(dead.action) + " closed while parked — cannot restore")
      return
    }
    // A restored window that is closed for real leaves a redo entry
    // pointing at nothing; drop it so redo never "parks" a dead window.
    var redo = root.model.redo || []
    for (var r = 0; r < redo.length; r++) {
      if (redo[r] && redo[r].address === addr) { root.commit(Model.dropAddress(root.model, addr)); break }
    }
    if (!root.trackAppClose) return
    var snapshot = root.snapshots[addr]
    if (!snapshot) return
    if (snapshot.openedAt && (Date.now() - snapshot.openedAt) < 800) return
    var previous = root.model
    var result = Model.pushRelaunch(previous, snapshot)
    if (result.action) {
      root.commit(result.state)
      root.applyKills(result.kills, previous)
    }
  }

  function handleMove(address, workspace) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    var ws = String(workspace || "")
    if (root.consume(addr, "move")) return
    var parked = Model.findParked(root.model, addr) !== -1
    if (parked && ws !== root.parkWorkspace) {
      // Someone else brought it back; it is visible, so stop tracking it.
      root.commit(Model.dropAddress(root.model, addr))
      return
    }
    if (!parked && ws === root.parkWorkspace) {
      var snap = root.snapshots[addr] ? Object.assign({}, root.snapshots[addr]) : null
      if (!snap) {
        var handle = root.liveHandle(addr)
        snap = handle ? root.snapshotFromHandle(handle) : null
      }
      if (!snap) return
      if (Model.isSpecialWorkspace(snap.workspace)) snap.workspace = ""
      snap.recovered = true
      var result = Model.pushRecovered(root.model, snap)
      if (result.action) root.commit(result.state)
    }
  }

  // ------------------------------------------------------------- bindings

  function refreshBindStatus() {
    if (bindsProcess.running) { bindsProcess.rerun = true; return }
    bindsProcess.mode = "status"
    bindsProcess.command = ["python3", root.bindsBin, "status", "--json"]
    bindsProcess.running = true
  }

  function installBinds(optionsJson) {
    var opts = {}
    try { opts = JSON.parse(optionsJson || "{}") || {} } catch (e) { opts = {} }
    var args = ["python3", root.bindsBin, "install", "--json"]
    var keyRe = /^[A-Za-z0-9_ +]{1,48}$/
    var actions = ["undo", "redo", "timeline", "close"]
    for (var i = 0; i < actions.length; i++) {
      var a = actions[i]
      if (opts[a] && keyRe.test(String(opts[a]))) args.push("--" + a, String(opts[a]))
    }
    function list(name) {
      var items = Array.isArray(opts[name]) ? opts[name] : []
      var clean = []
      for (var j = 0; j < items.length; j++)
        if (actions.indexOf(String(items[j])) !== -1) clean.push(String(items[j]))
      return clean
    }
    var skip = list("skip")
    var replace = list("replace")
    if (opts.replace && opts.replace.indexOf && opts.replace.indexOf("park") !== -1) replace.push("park")
    if (skip.length) args.push("--skip", skip.join(","))
    if (replace.length) args.push("--replace", replace.join(","))
    if (bindsProcess.running) return "busy"
    bindsProcess.mode = "install"
    bindsProcess.command = args
    bindsProcess.running = true
    return "installing"
  }

  function removeBinds() {
    if (bindsProcess.running) return "busy"
    bindsProcess.mode = "remove"
    bindsProcess.command = ["python3", root.bindsBin, "remove", "--json"]
    bindsProcess.running = true
    return "removing"
  }

  function maybeOfferSetup() {
    if (root.setupOffered || !root.bindsStatus) return
    if (root.bindsInstalled || root.setupDismissed) return
    root.setupOffered = true
    try {
      if (root.shell && typeof root.shell.isPluginOpen === "function" && root.shell.isPluginOpen(root.pluginId)) return
      if (root.shell && typeof root.shell.summon === "function")
        root.shell.summon(root.pluginId, JSON.stringify({ view: "setup", source: "auto" }))
    } catch (e) {}
  }

  function openTimeline() {
    try {
      if (root.shell && typeof root.shell.toggle === "function")
        root.shell.toggle(root.pluginId, JSON.stringify({ view: "timeline" }))
    } catch (e) {}
  }

  function statusJson() {
    var summary = Model.statusSummary(root.model)
    summary.result = root.lastResult
    summary.addresses = Model.parkedAddresses(root.model)
    summary.journal = root.journalStatus
    summary.session = root.session ? root.session.slice(0, 12) : ""
    summary.binds = root.bindsStatus ? !!root.bindsStatus.installed : null
    return JSON.stringify(summary)
  }

  // --------------------------------------------------------------- timers

  Timer { id: toastTimer; interval: 1800; repeat: false; onTriggered: { root.toastOpen = false; root.toastText = "" } }
  Timer { id: noticeTimer; interval: 60000; repeat: false; onTriggered: root.recoveryNotice = "" }
  Timer { id: persistDebounce; interval: 40; repeat: false; onTriggered: root.flushJournal() }
  Timer { id: reconcileTimer; interval: 500; repeat: false; onTriggered: root.reconcile() }
  Timer { id: expectSweep; interval: 5200; repeat: false; onTriggered: root.sweepExpected() }
  Timer { id: cacheDebounce; interval: 150; repeat: false; onTriggered: root.cacheToplevels() }
  Timer { id: refreshDebounce; interval: 60; repeat: false; onTriggered: { try { Hyprland.refreshToplevels() } catch (e) {}; cacheDebounce.restart() } }

  Timer {
    id: adoptTimer
    property var pending: []
    interval: 250
    repeat: false
    function queue(address) { pending = pending.concat([address]); restart() }
    onTriggered: {
      var list = pending
      pending = []
      for (var i = 0; i < list.length; i++) root.adoptIfStranded(list[i])
    }
  }

  Timer {
    id: animClear
    property var pending: []
    interval: 120
    repeat: false
    function queue(address) { pending = pending.concat([address]); restart() }
    onTriggered: {
      var list = pending
      pending = []
      for (var i = 0; i < list.length; i++) root.setNoAnim(list[i], false)
    }
  }

  // ------------------------------------------------------------ processes

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    blockLoading: true
    printErrors: false
    onLoaded: root.reloadSettings()
    onFileChanged: { shellConfigFile.reload(); root.reloadSettings() }
    onLoadFailed: root.reloadSettings()
  }

  Process {
    id: journalReader
    running: false
    stdout: StdioCollector { id: journalReaderOut; waitForEnd: true }
    onExited: function() { root.onJournalRead(journalReaderOut.text) }
  }

  Process {
    id: journalWriter
    property string payload: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: journalWriterOut; waitForEnd: true }
    onStarted: {
      journalWriter.write(payload)
      journalWriter.stdinEnabled = false
    }
    onExited: function(code) {
      journalWriter.stdinEnabled = true
      if (code !== 0) console.warn("reprieve: journal write failed:", String(journalWriterOut.text || "").slice(0, 200))
      else root.journalStatus = "ok"
      if (root.journalDirty) persistDebounce.restart()
    }
  }

  Process {
    id: quarantineProcess
    running: false
    onExited: function() { if (root.journalDirty) persistDebounce.restart() }
  }

  Process {
    id: bindsProcess
    property string mode: "status"
    property bool rerun: false
    running: false
    stdout: StdioCollector { id: bindsOut; waitForEnd: true }
    onExited: function() {
      var data = null
      try { data = JSON.parse(String(bindsOut.text || "").slice(0, 65536)) } catch (e) {}
      if (mode === "status") {
        if (data) root.bindsStatus = data
        root.maybeOfferSetup()
      } else {
        root.lastInstallResult = data || { status: "error", error: "no response" }
        if (mode === "install" && data && data.status === "ok") root.toast("✓ Reprieve is active")
        else if (mode === "remove" && data && data.status === "ok") root.toast("Reprieve bindings removed")
        rerun = true
      }
      if (rerun) { rerun = false; Qt.callLater(root.refreshBindStatus) }
    }
  }

  Timer {
    id: mediaTimeout
    interval: 2500
    repeat: false
    onTriggered: if (mediaProcess.running) mediaProcess.running = false
  }

  Process {
    id: mediaProcess
    running: false
    stdout: StdioCollector { id: mediaOut; waitForEnd: true }
    onRunningChanged: { if (running) mediaTimeout.restart(); else mediaTimeout.stop() }
    onExited: function() {
      mediaTimeout.stop()
      if (root.mediaJobKind === "pause") {
        var payload = null
        try { payload = Model.sanitizeMedia(JSON.parse(String(mediaOut.text || "").slice(0, 4096))) } catch (e) {}
        if (root.mediaJobAddress && payload) {
          if (Model.findParked(root.model, root.mediaJobAddress) !== -1)
            root.commit(Model.attachMedia(root.model, root.mediaJobAddress, payload))
          else
            root.requestResume(payload)
        }
      }
      root.mediaJobKind = ""
      root.mediaJobAddress = ""
      root.pumpMedia()
    }
  }

  // --------------------------------------------------------------- wiring

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { cacheDebounce.restart() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String((event && event.name) || "")
      var data = String((event && event.data) || "")
      if (name === "openwindow") {
        var parts = data.split(",")
        var address = Model.normalizeAddress(parts[0])
        if (address) root.patchSnapshot(address, { openedAt: Date.now(), workspace: String(parts[1] || ""), class: String(parts[2] || "") })
        // A dialog spawned by a parked app opens on the parked app's
        // workspace, i.e. hidden. Give it a timeline entry.
        if (address && String(parts[1] || "") === root.parkWorkspace) adoptTimer.queue(address)
        refreshDebounce.restart()
      } else if (name === "closewindow") {
        root.handleClose(data.split(",")[0])
        cacheDebounce.restart()
      } else if (name === "movewindowv2") {
        var mv = data.split(",")
        root.handleMove(mv[0], mv.slice(2).join(","))
        root.patchSnapshot(mv[0], { workspace: mv.slice(2).join(",") })
      } else if (name === "changefloatingmode") {
        var fl = data.split(",")
        root.patchSnapshot(fl[0], { floating: fl[1] === "1", floatingKnown: true })
      } else if (name === "fullscreen") {
        refreshDebounce.restart()
      }
    }
  }

  GlobalShortcut { appid: root.pluginId; name: "undo"; description: "Restore the last parked window"; onPressed: root.undoLast() }
  GlobalShortcut { appid: root.pluginId; name: "redo"; description: "Park it again"; onPressed: root.redoLast() }
  GlobalShortcut { appid: root.pluginId; name: "park"; description: "Park window (undoable close)"; onPressed: root.parkActive() }
  GlobalShortcut { appid: root.pluginId; name: "close"; description: "Close window permanently"; onPressed: root.closeActive() }
  GlobalShortcut { appid: root.pluginId; name: "timeline"; description: "Reprieve timeline"; onPressed: root.openTimeline() }

  IpcHandler {
    target: "tech.greyforge.reprieve"

    function park(): string { return root.parkActive() }
    function parkWindow(address: string): string { return root.parkWindow(address) }
    function close(): string { return root.closeActive() }
    function undo(): string { return root.undoLast() }
    function redo(): string { return root.redoLast() }
    function restoreAt(arg: string): string {
      var index = 0
      var here = false
      try {
        var parsed = JSON.parse(arg || "{}")
        index = Number(parsed.index)
        here = parsed.here === true
      } catch (e) {
        index = Number(arg)
      }
      return root.restoreAt(index, here)
    }
    function restoreAll(): string { return root.restoreAll() }
    function closeParked(address: string): string { return root.closeParked(address) }
    function clear(): string { return root.clearHistory() }
    function reset(): string { return root.resetAll() }
    function reconcile(): string { var r = root.reconcile(); return JSON.stringify(r || {}) }
    function status(): string { return root.statusJson() }
    function setShowToast(arg: string): string {
      var on = arg !== "false" && arg !== "0" && arg !== "off"
      root.setShowToast(on)
      return on ? "on" : "off"
    }
    function toggleShowToast(): string { var on = !root.showToast; root.setShowToast(on); return on ? "on" : "off" }
    function bindsStatus(): string { root.refreshBindStatus(); return JSON.stringify(root.bindsStatus || {}) }
    function installBinds(arg: string): string { return root.installBinds(arg) }
    function removeBinds(): string { return root.removeBinds() }
  }

  Component.onCompleted: {
    root.reloadSettings()
    root.model = Model.createState({ max: root.maxStack })
    root.publish()
    root.cacheToplevels()
    try { Hyprland.refreshToplevels() } catch (e) {}
    root.readJournal()
    root.refreshBindStatus()
  }

  Component.onDestruction: root.stopMedia()
}
