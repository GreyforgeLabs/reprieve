// Pure undo/redo stack for compositor window close.
// QML imports this; Node tests require() it. No I/O, no Hyprland.

var PARK_WORKSPACE = "special:desktop-undo"
var DEFAULT_MAX = 10
var MIN_MAX = 1
var MAX_MAX = 20

function defaultExcludedClasses() {
  return {
    "org.omarchy.screensaver": true,
    "org.omarchy.lock": true,
    "org.omarchy.polkit": true,
    "hyprland-share-picker": true,
    "xdg-desktop-portal-hyprland": true
  }
}

function clampMax(value) {
  var n = Number(value)
  if (!isFinite(n)) return DEFAULT_MAX
  n = Math.floor(n)
  if (n < MIN_MAX) return MIN_MAX
  if (n > MAX_MAX) return MAX_MAX
  return n
}

function createState(opts) {
  opts = opts || {}
  return {
    undo: [],
    redo: [],
    max: clampMax(opts.max),
    excluded: opts.excluded || defaultExcludedClasses(),
    parkWorkspace: opts.parkWorkspace || PARK_WORKSPACE
  }
}

function cloneState(state) {
  return {
    undo: (state.undo || []).slice(),
    redo: (state.redo || []).slice(),
    max: clampMax(state.max),
    excluded: state.excluded || defaultExcludedClasses(),
    parkWorkspace: state.parkWorkspace || PARK_WORKSPACE
  }
}

function normalizeAddress(value) {
  var text = String(value || "").trim()
  if (!text) return ""
  if (text.slice(0, 2) === "0x" || text.slice(0, 2) === "0X") text = text.slice(2)
  if (!text) return ""
  return "0x" + text
}

function isSpecialWorkspace(name) {
  return String(name || "").indexOf("special:") === 0
}

function canPark(snapshot, state) {
  if (!snapshot) return false
  var address = normalizeAddress(snapshot.address)
  if (!address) return false
  var klass = String(snapshot.class || "")
  if (!klass) return false
  var excluded = (state && state.excluded) || defaultExcludedClasses()
  if (excluded[klass]) return false
  var workspace = String(snapshot.workspace || "")
  var park = (state && state.parkWorkspace) || PARK_WORKSPACE
  if (workspace === park) return false
  if (isSpecialWorkspace(workspace)) return false
  return true
}

function canRelaunch(snapshot, state) {
  if (!snapshot) return false
  var klass = String(snapshot.class || "")
  if (!klass) return false
  var excluded = (state && state.excluded) || defaultExcludedClasses()
  if (excluded[klass]) return false
  if (isSpecialWorkspace(snapshot.workspace)) return false
  return !!relaunchCommand(snapshot)
}

function sanitizeLabel(value, maxLen) {
  var title = String(value == null ? "" : value)
  var out = ""
  for (var i = 0; i < title.length && out.length < maxLen; i++) {
    var code = title.charCodeAt(i)
    if (code < 32) continue
    out += title.charAt(i)
  }
  out = out.replace(/\s+/g, " ").trim()
  if (out.length > maxLen) out = out.slice(0, Math.max(0, maxLen - 3)) + "..."
  return out || "window"
}

function shortLabel(snapshot) {
  return sanitizeLabel((snapshot && (snapshot.title || snapshot.class)) || "window", 52)
}

function toastLabel(snapshot) {
  return sanitizeLabel((snapshot && (snapshot.label || snapshot.title || snapshot.class)) || "window", 32)
}

function parkAction(snapshot) {
  return {
    type: "park",
    address: normalizeAddress(snapshot.address),
    workspace: String(snapshot.workspace || ""),
    floating: !!snapshot.floating,
    fullscreen: Number(snapshot.fullscreen || 0),
    class: String(snapshot.class || ""),
    title: sanitizeLabel(snapshot.title || snapshot.class || "window", 52),
    pid: Number(snapshot.pid || 0),
    media: snapshot.media || null,
    label: shortLabel(snapshot)
  }
}

function relaunchAction(snapshot) {
  return {
    type: "relaunch",
    address: normalizeAddress(snapshot.address),
    workspace: String(snapshot.workspace || ""),
    class: String(snapshot.class || ""),
    title: sanitizeLabel(snapshot.title || snapshot.class || "window", 52),
    label: shortLabel(snapshot)
  }
}

function capUndo(undo, max, kills) {
  var next = undo.slice()
  while (next.length > max) {
    var dropped = next.shift()
    if (dropped && dropped.type === "park" && dropped.address)
      kills.push(dropped.address)
  }
  return next
}

function pushPark(state, snapshot) {
  if (!canPark(snapshot, state)) {
    return { state: state, kills: [], action: null, reason: "excluded" }
  }
  var next = cloneState(state)
  var action = parkAction(snapshot)
  next.undo = next.undo.concat([action])
  next.redo = []
  var kills = []
  next.undo = capUndo(next.undo, next.max, kills)
  return { state: next, kills: kills, action: action, reason: "parked" }
}

function pushRelaunch(state, snapshot) {
  if (!canRelaunch(snapshot, state)) {
    return { state: state, kills: [], action: null, reason: "skip" }
  }
  var next = cloneState(state)
  var action = relaunchAction(snapshot)
  next.undo = next.undo.concat([action])
  next.redo = []
  var kills = []
  next.undo = capUndo(next.undo, next.max, kills)
  return { state: next, kills: kills, action: action, reason: "recorded" }
}

function undo(state) {
  if (!state || !state.undo || state.undo.length === 0) {
    return { state: state, effects: [], action: null }
  }
  return undoAt(state, state.undo.length - 1, null)
}

function undoAt(state, index, opts) {
  opts = opts || {}
  if (!state || !state.undo || index < 0 || index >= state.undo.length) {
    return { state: state, effects: [], action: null }
  }
  var next = cloneState(state)
  var action = next.undo[index]
  next.undo = next.undo.slice(0, index).concat(next.undo.slice(index + 1))
  next.redo = next.redo.concat([action])
  var effects = undoEffects(action, next)
  var workspace = String(opts.workspace || "")
  if (workspace && !isSpecialWorkspace(workspace) && effects.length && effects[0].type === "restore") {
    effects[0] = Object.assign({}, effects[0], { workspace: workspace, here: true })
  }
  return { state: next, effects: effects, action: action }
}

function redo(state) {
  if (!state || !state.redo || state.redo.length === 0) {
    return { state: state, effects: [], action: null }
  }
  var next = cloneState(state)
  var action = next.redo[next.redo.length - 1]
  next.redo = next.redo.slice(0, -1)
  next.undo = next.undo.concat([action])
  var kills = []
  next.undo = capUndo(next.undo, next.max, kills)
  var effects = redoEffects(action, next)
  for (var i = 0; i < kills.length; i++)
    effects.push({ type: "close", address: kills[i] })
  return { state: next, effects: effects, action: action }
}

function undoEffects(action, state) {
  if (!action) return []
  if (action.type === "park") {
    return [
      {
        type: "restore",
        address: action.address,
        workspace: action.workspace,
        floating: !!action.floating,
        fullscreen: Number(action.fullscreen || 0),
        class: action.class || "",
        media: action.media || null,
        pid: Number(action.pid || 0)
      }
    ]
  }
  if (action.type === "relaunch") {
    return [{
      type: "relaunch",
      class: action.class || "",
      workspace: action.workspace || ""
    }]
  }
  return []
}

function redoEffects(action, state) {
  if (!action) return []
  if (action.type === "park") {
    return [{
      type: "park",
      address: action.address,
      workspace: (state && state.parkWorkspace) || PARK_WORKSPACE,
      class: action.class || "",
      pid: Number(action.pid || 0),
      label: action.label || ""
    }]
  }
  // Relaunch redo would mean closing the window we just started. Skip;
  // the user can Super+W that window if they want it gone again.
  return []
}

function parkedAddresses(state) {
  var out = []
  var undo = (state && state.undo) || []
  for (var i = 0; i < undo.length; i++) {
    if (undo[i] && undo[i].type === "park" && undo[i].address)
      out.push(undo[i].address)
  }
  return out
}

function attachMedia(state, address, media) {
  var addr = normalizeAddress(address)
  if (!addr || !state) return state
  var next = cloneState(state)
  function withMedia(action) {
    if (action && action.type === "park" && action.address === addr)
      return Object.assign({}, action, { media: media || null })
    return action
  }
  next.undo = next.undo.map(withMedia)
  next.redo = next.redo.map(withMedia)
  return next
}

function dropAddress(state, address) {
  var addr = normalizeAddress(address)
  if (!addr) return state
  var next = cloneState(state)
  function keep(action) {
    return !(action && action.type === "park" && action.address === addr)
  }
  next.undo = next.undo.filter(keep)
  next.redo = next.redo.filter(keep)
  return next
}

function luaString(value) {
  return String(value == null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function relaunchCommand(snapshot) {
  var klass = String((snapshot && snapshot.class) || "")
  if (klass === "google-chrome" || klass === "chromium" || klass === "brave-browser"
      || klass === "Brave-browser" || klass === "firefox" || klass === "firefox-esr") {
    return ["omarchy-launch-browser"]
  }
  var pwa = klass.match(/^(?:chrome|chromium|brave|google-chrome)-([A-Za-z0-9.-]+)__-Default$/i)
  if (pwa) {
    var host = pwa[1].replace(/_/g, ".")
    if (!/^[A-Za-z0-9.-]+$/.test(host)) return null
    return ["omarchy-launch-webapp", "https://" + host]
  }
  return null
}

function reset(state) {
  return createState({
    max: state && state.max,
    excluded: state && state.excluded,
    parkWorkspace: state && state.parkWorkspace
  })
}

function statusSummary(state) {
  var undo = (state && state.undo) || []
  var redo = (state && state.redo) || []
  var last = undo.length ? undo[undo.length - 1] : null
  return {
    undo: undo.length,
    redo: redo.length,
    last: last ? (last.label || last.class || last.type) : "",
    parked: parkedAddresses(state).length
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    PARK_WORKSPACE: PARK_WORKSPACE,
    DEFAULT_MAX: DEFAULT_MAX,
    defaultExcludedClasses: defaultExcludedClasses,
    clampMax: clampMax,
    createState: createState,
    cloneState: cloneState,
    normalizeAddress: normalizeAddress,
    isSpecialWorkspace: isSpecialWorkspace,
    canPark: canPark,
    canRelaunch: canRelaunch,
    sanitizeLabel: sanitizeLabel,
    shortLabel: shortLabel,
    pushPark: pushPark,
    pushRelaunch: pushRelaunch,
    toastLabel: toastLabel,
    undo: undo,
    undoAt: undoAt,
    redo: redo,
    attachMedia: attachMedia,
    parkedAddresses: parkedAddresses,
    dropAddress: dropAddress,
    luaString: luaString,
    relaunchCommand: relaunchCommand,
    reset: reset,
    statusSummary: statusSummary
  }
}
