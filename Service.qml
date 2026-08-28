import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "UndoModel.js" as UndoModel

// Headless Hyprland undo stack. Parks Super+W closes onto a hidden special
// workspace instead of killing the process. Never listens to key events and
// never binds Ctrl+Z — those two are how compositor-wide undo plugins hang
// a session.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "io.github.greyforgelabs.desktop-undo"
  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string mediaBin: pluginDir + "/bin/media"
  readonly property string parkWorkspace: UndoModel.PARK_WORKSPACE
  readonly property int maxStack: UndoModel.clampMax(setting("maxStack", UndoModel.DEFAULT_MAX))
  readonly property bool trackAppClose: setting("trackAppClose", true) !== false
  readonly property bool pauseMediaOnPark: setting("pauseMediaOnPark", true) !== false
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string statePath: stateHome + "/omarchy/desktop-undo.json"

  property var model: UndoModel.createState({ max: maxStack })
  property var snapshots: ({})
  property bool mutating: false
  property int mutatingToken: 0
  property var undoStack: []
  property var redoStack: []
  property int undoCount: 0
  property int redoCount: 0
  property string lastLabel: ""
  property string lastResult: ""
  property var mediaQueue: []
  property string mediaJobKind: ""
  property string mediaJobAddress: ""
  property bool showToast: true
  property bool toastOpen: false
  property string toastText: ""

  onMaxStackChanged: {
    if (!root.model) return
    var next = UndoModel.cloneState(root.model)
    next.max = maxStack
    root.model = next
    root.publish()
  }

  function setting(name, fallback) {
    try {
      var cfg = root.shell && root.shell.shellConfig ? root.shell.shellConfig : null
      var plugins = cfg && cfg.plugins ? cfg.plugins : []
      for (var i = 0; i < plugins.length; i++) {
        var entry = plugins[i]
        if (entry && entry.id === root.pluginId && entry[name] !== undefined && entry[name] !== null)
          return entry[name]
      }
    } catch (e) {}
    return fallback
  }

  function publish() {
    root.undoStack = (root.model && root.model.undo) ? root.model.undo.slice() : []
    root.redoStack = (root.model && root.model.redo) ? root.model.redo.slice() : []
    var summary = UndoModel.statusSummary(root.model)
    root.undoCount = summary.undo
    root.redoCount = summary.redo
    root.lastLabel = summary.last
  }

  function currentWorkspace() {
    try {
      var name = root.workspaceName(Hyprland.focusedWorkspace)
      if (name && !UndoModel.isSpecialWorkspace(name)) return name
    } catch (e) {}
    return ""
  }

  function loadState(raw) {
    try {
      var data = JSON.parse(raw || "{}")
      if (data && data.showToast !== undefined)
        root.showToast = data.showToast !== false
    } catch (e) {}
  }

  function persistState() {
    try {
      var data = {}
      try { data = JSON.parse(stateFile.text() || "{}") || {} } catch (e2) { data = {} }
      data.showToast = root.showToast
      stateFile.setText(JSON.stringify(data) + "\n")
    } catch (e) {}
  }

  function setShowToast(value) {
    root.showToast = value !== false
    root.persistState()
    if (root.showToast)
      root.toast("Toasts on — top right")
    else {
      root.toastOpen = false
      root.toastText = ""
    }
  }

  function toggleShowToast() {
    root.setShowToast(!root.showToast)
  }

  function toast(iconName, message) {
    var text = String(message || iconName || "")
    if (!text) return
    if (!root.showToast) return
    root.toastText = text
    root.toastOpen = true
    toastTimer.restart()
  }

  function enqueueMedia(kind, args, address) {
    root.mediaQueue = root.mediaQueue.concat([{ kind: kind, args: args, address: address || "" }])
    root.pumpMedia()
  }

  function pumpMedia() {
    if (mediaProcess.running || root.mediaQueue.length === 0) return
    var job = root.mediaQueue[0]
    root.mediaQueue = root.mediaQueue.slice(1)
    root.mediaJobKind = job.kind
    root.mediaJobAddress = job.address
    mediaProcess.command = job.args
    mediaProcess.running = true
  }

  function capText(raw, maxLen) {
    var text = String(raw == null ? "" : raw)
    if (text.length > maxLen) return text.slice(0, maxLen)
    return text
  }

  function parseMediaPayload(raw) {
    try {
      var payload = JSON.parse(root.capText(raw, 4096) || "{}")
      if (!payload || typeof payload !== "object") return null
      var muted = []
      var srcMuted = payload.muted || []
      for (var i = 0; i < srcMuted.length && muted.length < 32; i++) {
        var item = srcMuted[i]
        if (!item) continue
        muted.push({ index: Number(item.index || 0), pid: Number(item.pid || 0) })
      }
      var paused = []
      var srcPaused = payload.paused || []
      for (var j = 0; j < srcPaused.length && paused.length < 16; j++) {
        var name = root.capText(srcPaused[j], 200)
        if (name) paused.push(name)
      }
      if (!muted.length && !paused.length) return null
      return { muted: muted, paused: paused }
    } catch (e) {
      return null
    }
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
    var klass = String(snapshot.class || "")
    if (!pid && !klass) return
    root.enqueueMedia("pause", [
      "python3", root.mediaBin, "pause",
      "--pid", String(pid),
      "--class-name", klass
    ], snapshot.address)
  }

  function requestResume(media) {
    if (!media) return
    var muted = media.muted || []
    var paused = media.paused || []
    if (!muted.length && !paused.length) return
    root.enqueueMedia("resume", [
      "python3", root.mediaBin, "resume",
      "--payload", JSON.stringify(media)
    ], "")
  }

  function beginMutate() {
    root.mutating = true
    root.mutatingToken += 1
    var token = root.mutatingToken
    mutateTimer.token = token
    mutateTimer.restart()
  }

  function luaString(value) {
    return UndoModel.luaString(value)
  }

  function hyprDispatch(lua, legacy) {
    try {
      Hyprland.dispatch(Hyprland.usingLua ? lua : legacy)
    } catch (e) {
      console.warn("desktop-undo dispatch failed", e)
    }
  }

  // Omarchy's windowsIn/Out use popin 87% — that's the explode. Set no_anim
  // on the window *before* the move so park/restore is a cut, not a cartoon.
  function setNoAnim(address, on) {
    var addr = UndoModel.normalizeAddress(address)
    if (!addr) return
    var value = on ? "1" : "0"
    root.hyprDispatch(
      'hl.dsp.window.set_prop({ window = "address:' + root.luaString(addr)
        + '", prop = "no_anim", value = "' + value + '" })',
      "setprop address:" + addr + " noanim " + value)
  }

  function moveSilent(address, workspace) {
    var addr = UndoModel.normalizeAddress(address)
    if (!addr || !workspace) return
    root.setNoAnim(addr, true)
    root.hyprDispatch(
      'hl.dsp.window.move({ window = "address:' + root.luaString(addr)
        + '", workspace = "' + root.luaString(workspace) + '", follow = false })',
      "movetoworkspacesilent " + workspace + ",address:" + addr)
  }

  function liveHandle(address) {
    var addr = UndoModel.normalizeAddress(address)
    if (!addr || !Hyprland.toplevels) return null
    try {
      var list = Hyprland.toplevels.values || []
      for (var i = 0; i < list.length; i++) {
        var handle = list[i]
        if (handle && UndoModel.normalizeAddress(handle.address) === addr)
          return handle
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
    var address = UndoModel.normalizeAddress(handle.address)
    var cached = address && root.snapshots[address] ? root.snapshots[address] : {}
    var ipc = handle.lastIpcObject || {}
    return {
      address: address,
      class: String(handle.class || ipc.class || cached.class || ""),
      title: String(handle.title || ipc.title || cached.title || ""),
      workspace: root.workspaceName(handle.workspace) || cached.workspace || "",
      floating: handle.floating !== undefined ? !!handle.floating : !!ipc.floating || !!cached.floating,
      fullscreen: Number(handle.fullscreen !== undefined ? handle.fullscreen : (ipc.fullscreen || cached.fullscreen || 0)),
      pid: Number(ipc.pid || cached.pid || 0)
    }
  }

  function activeSnapshot() {
    var handle = null
    try { handle = Hyprland.activeToplevel } catch (e) {}
    if (handle) return root.snapshotFromHandle(handle)
    return null
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
        next[snap.address] = snap
      }
    } catch (e) {}
    root.snapshots = next
  }

  function applyKills(addresses) {
    if (!addresses || !addresses.length) return
    root.beginMutate()
    for (var i = 0; i < addresses.length; i++) {
      var address = addresses[i]
      if (!root.liveHandle(address)) continue
      root.setNoAnim(address, true)
      root.hyprDispatch(
        'hl.dsp.window.close({ window = "address:' + root.luaString(address) + '" })',
        "closewindow address:" + address)
    }
  }

  function applyEffects(effects) {
    if (!effects || !effects.length) return
    root.beginMutate()
    for (var i = 0; i < effects.length; i++) {
      var effect = effects[i]
      if (!effect) continue
      if (effect.type === "park") {
        if (!root.liveHandle(effect.address)) continue
        root.moveSilent(effect.address, effect.workspace)
        root.requestPause({ address: effect.address, pid: effect.pid, class: effect.class })
      } else if (effect.type === "restore") {
        root.restoreWindow(effect)
      } else if (effect.type === "relaunch") {
        root.relaunch(effect)
      } else if (effect.type === "close") {
        if (!root.liveHandle(effect.address)) continue
        root.setNoAnim(effect.address, true)
        root.hyprDispatch(
          'hl.dsp.window.close({ window = "address:' + root.luaString(effect.address) + '" })',
          "closewindow address:" + effect.address)
      }
    }
  }

  function restoreWindow(effect) {
    if (root.liveHandle(effect.address)) {
      var workspace = effect.workspace || "1"
      root.moveSilent(effect.address, workspace)
      if (root.currentWorkspace() !== workspace) {
        root.hyprDispatch(
          'hl.dsp.focus({ workspace = "' + root.luaString(workspace) + '" })',
          "workspace " + workspace)
      }
      if (effect.floating) {
        root.hyprDispatch(
          'hl.dsp.window.float({ window = "address:' + root.luaString(effect.address) + '", action = "set" })',
          "setfloating address:" + effect.address)
      }
      animClearTimer.address = effect.address
      animClearTimer.restart()
      root.requestResume(effect.media)
      return
    }
    root.relaunch(effect)
  }

  function relaunch(effect) {
    var command = UndoModel.relaunchCommand(effect)
    if (!command || !command.length) {
      root.lastResult = "gone"
      return
    }
    try {
      Quickshell.execDetached(command)
      root.lastResult = "relaunched"
    } catch (e) {
      console.warn("desktop-undo relaunch failed", e)
      root.lastResult = "error"
    }
  }

  function closeActive() {
    var snapshot = root.activeSnapshot()
    if (!snapshot || !snapshot.address) {
      root.lastResult = "empty"
      return "empty"
    }
    var cached = root.snapshots[snapshot.address]
    if (cached && !snapshot.class) snapshot.class = cached.class
    var result = UndoModel.pushPark(root.model, snapshot)
    if (result.reason !== "parked") {
      root.lastResult = result.reason
      return "passthrough"
    }
    root.model = result.state
    root.publish()
    root.beginMutate()
    root.moveSilent(snapshot.address, root.parkWorkspace)
    root.applyKills(result.kills)
    root.requestPause(snapshot)
    root.lastResult = "parked"
    root.toast("media-pause", "Parked " + UndoModel.toastLabel(result.action) + " — Super+Z to undo")
    return "parked"
  }

  function killActive() {
    var snapshot = root.activeSnapshot()
    if (!snapshot || !snapshot.address) {
      root.lastResult = "empty"
      return "empty"
    }
    root.beginMutate()
    root.hyprDispatch("hl.dsp.window.close()", "killactive")
    root.lastResult = "killed"
    return "killed"
  }

  function undoLast() {
    var result = UndoModel.undo(root.model)
    if (!result.action) {
      root.lastResult = "empty"
      return "empty"
    }
    root.model = result.state
    root.publish()
    root.applyEffects(result.effects)
    root.lastResult = "undone"
    var here = result.effects.length && result.effects[0].here
    root.toast("media-play", (here ? "Restored here: " : "Restored ") + UndoModel.toastLabel(result.action))
    return "undone"
  }

  function restoreAt(index, here) {
    var opts = {}
    if (here === true) {
      var workspace = root.currentWorkspace()
      if (workspace) opts.workspace = workspace
    }
    var result = UndoModel.undoAt(root.model, Number(index), opts)
    if (!result.action) {
      root.lastResult = "empty"
      return "empty"
    }
    root.model = result.state
    root.publish()
    root.applyEffects(result.effects)
    root.lastResult = here ? "here" : "undone"
    root.toast("media-play", (here ? "Restored here: " : "Restored ") + UndoModel.toastLabel(result.action))
    return root.lastResult
  }

  function redoLast() {
    var result = UndoModel.redo(root.model)
    if (!result.action) {
      root.lastResult = "empty"
      return "empty"
    }
    root.model = result.state
    root.publish()
    root.applyEffects(result.effects)
    root.lastResult = "redone"
    root.toast("media-pause", "Parked " + UndoModel.toastLabel(result.action) + " — Super+Z to undo")
    return "redone"
  }

  function recordExternalClose(address) {
    if (!root.trackAppClose || root.mutating) return
    var addr = UndoModel.normalizeAddress(address)
    if (!addr) return
    var parked = UndoModel.parkedAddresses(root.model)
    if (parked.indexOf(addr) !== -1) {
      root.model = UndoModel.dropAddress(root.model, addr)
      root.publish()
      return
    }
    var snapshot = root.snapshots[addr]
    if (!snapshot) return
    if (snapshot.openedAt && (Date.now() - snapshot.openedAt) < 800) return
    var result = UndoModel.pushRelaunch(root.model, snapshot)
    if (result.action) {
      root.model = result.state
      root.publish()
      root.applyKills(result.kills)
    }
  }

  function statusJson() {
    var summary = UndoModel.statusSummary(root.model)
    summary.result = root.lastResult
    return JSON.stringify(summary)
  }

  Timer {
    id: toastTimer
    interval: 1800
    repeat: false
    onTriggered: {
      root.toastOpen = false
      root.toastText = ""
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
  }

  Timer {
    id: mutateTimer
    property int token: 0
    interval: 350
    repeat: false
    onTriggered: if (root.mutatingToken === token) root.mutating = false
  }

  Timer {
    id: animClearTimer
    property string address: ""
    interval: 80
    repeat: false
    onTriggered: {
      if (address) root.setNoAnim(address, false)
      address = ""
    }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { cacheDebounce.restart() }
  }

  Timer {
    id: mediaTimeout
    interval: 2500
    repeat: false
    onTriggered: {
      if (mediaProcess.running) mediaProcess.running = false
    }
  }

  Process {
    id: mediaProcess
    running: false
    stdout: StdioCollector {
      id: mediaOut
      waitForEnd: true
    }
    onRunningChanged: {
      if (running) mediaTimeout.restart()
      else mediaTimeout.stop()
    }
    onExited: function() {
      mediaTimeout.stop()
      if (root.mediaJobKind === "pause") {
        var payload = root.parseMediaPayload(mediaOut.text)
        if (root.mediaJobAddress && payload) {
          var parked = UndoModel.parkedAddresses(root.model).indexOf(root.mediaJobAddress) !== -1
          if (parked) {
            root.model = UndoModel.attachMedia(root.model, root.mediaJobAddress, payload)
            root.publish()
          } else {
            root.requestResume(payload)
          }
        }
      }
      root.mediaJobKind = ""
      root.mediaJobAddress = ""
      root.pumpMedia()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String((event && event.name) || "")
      if (name === "openwindow") {
        var raw = String(event.data || "").split(",")[0]
        var address = UndoModel.normalizeAddress(raw)
        if (address) {
          var next = {}
          for (var key in root.snapshots) next[key] = root.snapshots[key]
          var existing = next[address] || {}
          existing.address = address
          existing.openedAt = Date.now()
          next[address] = existing
          root.snapshots = next
        }
        cacheDebounce.restart()
        return
      }
      if (name === "closewindow") {
        root.recordExternalClose(String(event.data || "").split(",")[0])
        cacheDebounce.restart()
      }
    }
  }

  Timer {
    id: cacheDebounce
    interval: 200
    repeat: false
    onTriggered: root.cacheToplevels()
  }

  GlobalShortcut {
    appid: root.pluginId
    name: "undo"
    description: "Undo last desktop window close"
    onPressed: root.undoLast()
  }

  GlobalShortcut {
    appid: root.pluginId
    name: "redo"
    description: "Redo last desktop window close"
    onPressed: root.redoLast()
  }

  GlobalShortcut {
    appid: root.pluginId
    name: "close"
    description: "Close window (undoable)"
    onPressed: root.closeActive()
  }

  GlobalShortcut {
    appid: root.pluginId
    name: "kill"
    description: "Close window permanently"
    onPressed: root.killActive()
  }

  IpcHandler {
    target: "io.github.greyforgelabs.desktop-undo"

    function close(): string { return root.closeActive() }
    function kill(): string { return root.killActive() }
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
    function status(): string { return root.statusJson() }
    function reset(): string {
      root.model = UndoModel.createState({ max: root.maxStack })
      root.publish()
      root.lastResult = "reset"
      return "reset"
    }
    function setShowToast(arg: string): string {
      var on = arg !== "false" && arg !== "0" && arg !== "off"
      root.setShowToast(on)
      return root.showToast ? "on" : "off"
    }
    function toggleShowToast(): string {
      root.toggleShowToast()
      return root.showToast ? "on" : "off"
    }
  }

  Component.onCompleted: {
    root.model = UndoModel.createState({ max: root.maxStack })
    if (root.setting("showToast", undefined) !== undefined && !stateFile.text())
      root.showToast = root.setting("showToast", true) !== false
    root.publish()
    root.cacheToplevels()
  }

  Component.onDestruction: root.stopMedia()
}
