// Reprieve — pure undo/redo model for compositor window close.
// QML imports this; Node tests require() it. No I/O, no Hyprland.
//
// Everything here treats window metadata (address, class, title, workspace,
// pid) as untrusted input. Anything that ends up inside a Hyprland dispatch
// string is validated by normalizeAddress()/normalizeWorkspace() first.

var PLUGIN_ID = "tech.greyforge.reprieve"
var PARK_WORKSPACE = "special:reprieve"
var DEFAULT_MAX = 10
var MIN_MAX = 1
var MAX_MAX = 20
var JOURNAL_SCHEMA = 1
var JOURNAL_MAX_BYTES = 262144
var JOURNAL_MAX_ENTRIES = 64
var LABEL_MAX = 52
var CLASS_MAX = 128

var ADDRESS_RE = /^0x[0-9a-f]{1,16}$/
var WORKSPACE_RE = /^[A-Za-z0-9_.:+-]{1,64}$/

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
    parkWorkspace: opts.parkWorkspace || PARK_WORKSPACE,
    sequence: Math.max(0, Math.floor(Number(opts.sequence) || 0))
  }
}

function cloneState(state) {
  state = state || {}
  return {
    undo: (state.undo || []).slice(),
    redo: (state.redo || []).slice(),
    max: clampMax(state.max),
    excluded: state.excluded || defaultExcludedClasses(),
    parkWorkspace: state.parkWorkspace || PARK_WORKSPACE,
    sequence: Math.max(0, Math.floor(Number(state.sequence) || 0))
  }
}

// Hyprland addresses are lowercase hex. Anything else is rejected outright
// so a hostile value can never reach a dispatch string.
function normalizeAddress(value) {
  var text = String(value == null ? "" : value).trim().toLowerCase()
  if (!text) return ""
  if (text.slice(0, 2) === "0x") text = text.slice(2)
  text = text.replace(/^0+(?=[0-9a-f])/, "")
  if (!text) return ""
  var out = "0x" + text
  return ADDRESS_RE.test(out) ? out : ""
}

function normalizeWorkspace(value) {
  var text = String(value == null ? "" : value).trim()
  if (!text) return ""
  return WORKSPACE_RE.test(text) ? text : ""
}

function isSpecialWorkspace(name) {
  return String(name || "").indexOf("special:") === 0
}

function clampInt(value, lo, hi, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.floor(n)
  if (n < lo || n > hi) return fallback
  return n
}

function sanitizeLabel(value, maxLen) {
  var title = String(value == null ? "" : value)
  var out = ""
  for (var i = 0; i < title.length && out.length < maxLen; i++) {
    var code = title.charCodeAt(i)
    if (code < 32 || code === 127) continue
    out += title.charAt(i)
  }
  out = out.replace(/\s+/g, " ").trim()
  if (out.length > maxLen) out = out.slice(0, Math.max(0, maxLen - 3)) + "..."
  return out || "window"
}

function sanitizeClass(value) {
  var text = String(value == null ? "" : value)
  var out = ""
  for (var i = 0; i < text.length && out.length < CLASS_MAX; i++) {
    var code = text.charCodeAt(i)
    if (code < 33 || code === 127) continue
    out += text.charAt(i)
  }
  return out
}

function shortLabel(snapshot) {
  return sanitizeLabel((snapshot && (snapshot.title || snapshot.class)) || "window", LABEL_MAX)
}

function toastLabel(snapshot) {
  return sanitizeLabel((snapshot && (snapshot.label || snapshot.title || snapshot.class)) || "window", 32)
}

function canPark(snapshot, state) {
  if (!snapshot) return false
  if (!normalizeAddress(snapshot.address)) return false
  var klass = sanitizeClass(snapshot.class)
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
  var klass = sanitizeClass(snapshot.class)
  if (!klass) return false
  var excluded = (state && state.excluded) || defaultExcludedClasses()
  if (excluded[klass]) return false
  if (isSpecialWorkspace(snapshot.workspace)) return false
  return !!relaunchCommand(snapshot)
}

function nextSequence(state) {
  return Math.max(0, Math.floor(Number(state.sequence) || 0)) + 1
}

function parkAction(snapshot, sequence) {
  var klass = sanitizeClass(snapshot.class)
  return {
    type: "park",
    address: normalizeAddress(snapshot.address),
    workspace: normalizeWorkspace(snapshot.workspace),
    floating: !!snapshot.floating,
    fullscreen: clampInt(snapshot.fullscreen, 0, 2, 0),
    fullscreenClient: clampInt(snapshot.fullscreenClient, 0, 2, 0),
    class: klass,
    title: sanitizeLabel(snapshot.title || klass || "window", LABEL_MAX),
    pid: clampInt(snapshot.pid, 0, 4194304, 0),
    media: sanitizeMedia(snapshot.media),
    label: shortLabel({ title: snapshot.title, class: klass }),
    sequence: sequence,
    recovered: snapshot.recovered === true
  }
}

function relaunchAction(snapshot, sequence) {
  var klass = sanitizeClass(snapshot.class)
  return {
    type: "relaunch",
    address: normalizeAddress(snapshot.address),
    workspace: normalizeWorkspace(snapshot.workspace),
    class: klass,
    title: sanitizeLabel(snapshot.title || klass || "window", LABEL_MAX),
    label: shortLabel({ title: snapshot.title, class: klass }),
    sequence: sequence
  }
}

// Media restoration payload: MPRIS players successfully paused, plus legacy
// PipeWire mute records (pid-matched on resume) for upgrade cleanup. Bounded
// and re-typed so a journal cannot smuggle anything else through.
function sanitizeMedia(media) {
  if (!media || typeof media !== "object") return null
  var muted = []
  var srcMuted = Array.isArray(media.muted) ? media.muted : []
  for (var i = 0; i < srcMuted.length && muted.length < 32; i++) {
    var item = srcMuted[i]
    if (!item || typeof item !== "object") continue
    var index = clampInt(item.index, 0, 2147483647, -1)
    if (index < 0) continue
    muted.push({ index: index, pid: clampInt(item.pid, 0, 4194304, 0) })
  }
  var paused = []
  var srcPaused = Array.isArray(media.paused) ? media.paused : []
  for (var j = 0; j < srcPaused.length && paused.length < 16; j++) {
    var name = String(srcPaused[j] == null ? "" : srcPaused[j])
    if (!/^org\.mpris\.MediaPlayer2\.[A-Za-z0-9_.-]{1,180}$/.test(name)) continue
    paused.push(name)
  }
  if (!muted.length && !paused.length) return null
  return { muted: muted, paused: paused }
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
  var addr = normalizeAddress(snapshot.address)
  // Re-parking an address already tracked replaces the stale entry.
  next.undo = next.undo.filter(function (a) { return !(a && a.address === addr) })
  next.redo = next.redo.filter(function (a) { return !(a && a.address === addr) })
  next.sequence = nextSequence(next)
  var action = parkAction(snapshot, next.sequence)
  next.undo = next.undo.concat([action])
  next.redo = []
  var kills = []
  next.undo = capUndo(next.undo, next.max, kills)
  return { state: next, kills: kills, action: action, reason: "parked" }
}

// Adopt a live window that is already sitting on the park workspace but
// that nobody remembers (stranded after a crash, moved there by hand, or an
// overflow close the app refused). Never closes anything.
function pushRecovered(state, snapshot) {
  var addr = normalizeAddress(snapshot && snapshot.address)
  if (!addr || !state) return { state: state, action: null, reason: "invalid" }
  if (findParked(state, addr) !== -1) return { state: state, action: null, reason: "tracked" }
  var klass = sanitizeClass(snapshot.class) || "window"
  var excluded = (state && state.excluded) || defaultExcludedClasses()
  if (excluded[klass]) return { state: state, action: null, reason: "excluded" }
  var next = cloneState(state)
  next.sequence = nextSequence(next)
  var ws = normalizeWorkspace(snapshot.workspace)
  if (isSpecialWorkspace(ws)) ws = ""
  var action = parkAction({
    address: addr,
    workspace: ws,
    class: klass,
    title: snapshot.title || "",
    pid: snapshot.pid || 0,
    floating: !!snapshot.floating,
    fullscreen: 0,
    fullscreenClient: 0,
    recovered: true
  }, next.sequence)
  next.undo = next.undo.concat([action])
  return { state: next, action: action, reason: "recovered" }
}

function pushRelaunch(state, snapshot) {
  if (!canRelaunch(snapshot, state)) {
    return { state: state, kills: [], action: null, reason: "skip" }
  }
  var next = cloneState(state)
  next.sequence = nextSequence(next)
  var action = relaunchAction(snapshot, next.sequence)
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
  var effects = undoEffects(action, next, opts.workspace)
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

// `here` is the workspace to restore onto instead of the recorded one. A
// recovered window (no recorded workspace) always needs a fallback; the
// caller passes the current workspace for that.
function undoEffects(action, state, here) {
  if (!action) return []
  var hereWs = normalizeWorkspace(here)
  if (hereWs && isSpecialWorkspace(hereWs)) hereWs = ""
  if (action.type === "park") {
    var recorded = normalizeWorkspace(action.workspace)
    if (isSpecialWorkspace(recorded)) recorded = ""
    var target = hereWs || recorded
    return [
      {
        type: "restore",
        address: action.address,
        workspace: target,
        here: !!hereWs && hereWs !== recorded,
        floating: !!action.floating,
        fullscreen: clampInt(action.fullscreen, 0, 2, 0),
        fullscreenClient: clampInt(action.fullscreenClient, 0, 2, 0),
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
      workspace: hereWs || action.workspace || ""
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

function findParked(state, address) {
  var addr = normalizeAddress(address)
  if (!addr) return -1
  var undo = (state && state.undo) || []
  for (var i = 0; i < undo.length; i++) {
    if (undo[i] && undo[i].type === "park" && undo[i].address === addr) return i
  }
  return -1
}

function attachMedia(state, address, media) {
  var addr = normalizeAddress(address)
  if (!addr || !state) return state
  var clean = sanitizeMedia(media)
  var next = cloneState(state)
  function withMedia(action) {
    if (action && action.type === "park" && action.address === addr)
      return Object.assign({}, action, { media: clean })
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

// A parked window's process died. Keep the timeline entry as a safe Reopen
// when the class is allowlisted; otherwise the entry is gone for good.
function markDead(state, address) {
  var addr = normalizeAddress(address)
  var result = { state: state, converted: false, removed: false, action: null }
  if (!addr || !state) return result
  var next = cloneState(state)
  function convert(action) {
    if (!(action && action.type === "park" && action.address === addr)) return action
    result.action = action
    if (relaunchCommand(action)) {
      result.converted = true
      var re = relaunchAction(action, action.sequence)
      re.address = ""
      return re
    }
    result.removed = true
    return null
  }
  next.undo = next.undo.map(convert).filter(function (a) { return !!a })
  next.redo = next.redo.filter(function (a) {
    if (a && a.type === "park" && a.address === addr) { result.action = a; result.removed = !result.converted; return false }
    return true
  })
  result.state = next
  return result
}

function luaString(value) {
  return String(value == null ? "" : value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

// Narrow allowlist. Nothing here is derived from argv or the environment.
function relaunchCommand(snapshot) {
  var klass = sanitizeClass(snapshot && snapshot.class)
  if (klass === "google-chrome" || klass === "chromium" || klass === "brave-browser"
      || klass === "Brave-browser" || klass === "firefox" || klass === "firefox-esr") {
    return ["omarchy-launch-browser"]
  }
  var pwa = klass.match(/^(?:chrome|chromium|brave|google-chrome)-([A-Za-z0-9._-]+)__-Default$/i)
  if (pwa) {
    var host = pwa[1].replace(/_/g, ".")
    if (!/^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/.test(host)) return null
    if (host.indexOf("..") !== -1) return null
    return ["omarchy-launch-webapp", "https://" + host]
  }
  return null
}

// Restore every live parked window. Oldest first so the stack order the
// user built up is what they see reappear; each restored action lands on
// redo so it can be re-parked.
function restoreAll(state, currentWorkspace) {
  if (!state) return { state: state, effects: [], actions: [] }
  var next = cloneState(state)
  var effects = []
  var actions = []
  var keep = []
  for (var i = 0; i < next.undo.length; i++) {
    var action = next.undo[i]
    if (action && action.type === "park") {
      actions.push(action)
      var target = normalizeWorkspace(action.workspace)
      var fx = undoEffects(action, next, target ? "" : currentWorkspace)
      for (var j = 0; j < fx.length; j++) effects.push(fx[j])
    } else if (action) {
      keep.push(action)
    }
  }
  next.undo = keep
  next.redo = next.redo.concat(actions)
  return { state: next, effects: effects, actions: actions }
}

// clear() never orphans live windows: it refuses outright while any parked
// window is tracked. Callers restore or close them first.
function clear(state) {
  var live = parkedAddresses(state).length
  if (live > 0) return { state: state, ok: false, live: live }
  var next = cloneState(state)
  next.undo = []
  next.redo = []
  return { state: next, ok: true, live: 0 }
}

// reset() = restore everything, then forget history. Settings survive.
function reset(state, currentWorkspace) {
  var restored = restoreAll(state, currentWorkspace)
  var next = createState({
    max: state && state.max,
    excluded: state && state.excluded,
    parkWorkspace: state && state.parkWorkspace,
    sequence: state && state.sequence
  })
  return { state: next, effects: restored.effects, actions: restored.actions }
}

function statusSummary(state) {
  var undo = (state && state.undo) || []
  var redo = (state && state.redo) || []
  var last = undo.length ? undo[undo.length - 1] : null
  var recovered = 0
  for (var i = 0; i < undo.length; i++)
    if (undo[i] && undo[i].type === "park" && undo[i].recovered) recovered++
  return {
    undo: undo.length,
    redo: redo.length,
    last: last ? (last.label || last.class || last.type) : "",
    parked: parkedAddresses(state).length,
    recovered: recovered
  }
}

// ---------------------------------------------------------------------------
// Recovery journal
//
// Only what is needed to find a parked window again after the shell
// restarts: address, where it came from, how it looked, and which process
// owned it. No argv, no environment, no titles.

function toJournal(state, session) {
  var entries = []
  var undo = (state && state.undo) || []
  for (var i = 0; i < undo.length && entries.length < JOURNAL_MAX_ENTRIES; i++) {
    var a = undo[i]
    if (!a || a.type !== "park" || !a.address) continue
    var entry = {
      address: a.address,
      workspace: normalizeWorkspace(a.workspace),
      class: sanitizeClass(a.class),
      floating: !!a.floating,
      fullscreen: clampInt(a.fullscreen, 0, 2, 0),
      fullscreenClient: clampInt(a.fullscreenClient, 0, 2, 0),
      pid: clampInt(a.pid, 0, 4194304, 0),
      sequence: clampInt(a.sequence, 0, 2147483647, 0)
    }
    if (a.media) entry.media = sanitizeMedia(a.media)
    if (a.recovered) entry.recovered = true
    entries.push(entry)
  }
  return {
    schema: JOURNAL_SCHEMA,
    session: String(session || ""),
    sequence: clampInt(state && state.sequence, 0, 2147483647, 0),
    entries: entries
  }
}

// Returns { status, entries, sequence }. status is one of:
//   "empty"   — nothing persisted
//   "invalid" — malformed; caller should quarantine
//   "stale"   — valid but from another compositor session
//   "ok"      — usable entries (already validated and re-typed)
function parseJournal(raw, session) {
  var text = String(raw == null ? "" : raw)
  if (!text.trim()) return { status: "empty", entries: [], sequence: 0 }
  if (text.length > JOURNAL_MAX_BYTES) return { status: "invalid", entries: [], sequence: 0, reason: "oversized" }
  var data
  try { data = JSON.parse(text) } catch (e) { return { status: "invalid", entries: [], sequence: 0, reason: "json" } }
  if (!data || typeof data !== "object" || Array.isArray(data))
    return { status: "invalid", entries: [], sequence: 0, reason: "shape" }
  if (data.schema !== JOURNAL_SCHEMA)
    return { status: "invalid", entries: [], sequence: 0, reason: "schema" }
  if (typeof data.session !== "string" || !Array.isArray(data.entries))
    return { status: "invalid", entries: [], sequence: 0, reason: "shape" }
  if (!session || data.session !== String(session))
    return { status: "stale", entries: [], sequence: 0, reason: "session" }
  var entries = []
  for (var i = 0; i < data.entries.length && entries.length < JOURNAL_MAX_ENTRIES; i++) {
    var e = data.entries[i]
    if (!e || typeof e !== "object") continue
    var address = normalizeAddress(e.address)
    if (!address) continue
    entries.push({
      address: address,
      workspace: normalizeWorkspace(e.workspace),
      class: sanitizeClass(e.class),
      floating: e.floating === true,
      fullscreen: clampInt(e.fullscreen, 0, 2, 0),
      fullscreenClient: clampInt(e.fullscreenClient, 0, 2, 0),
      pid: clampInt(e.pid, 0, 4194304, 0),
      sequence: clampInt(e.sequence, 0, 2147483647, 0),
      media: sanitizeMedia(e.media),
      recovered: e.recovered === true
    })
  }
  entries.sort(function (a, b) { return a.sequence - b.sequence })
  return { status: "ok", entries: entries, sequence: clampInt(data.sequence, 0, 2147483647, 0) }
}

// Bring three sources into agreement: what we remember (state), what we
// persisted (journal entries), and what Hyprland actually has (live).
//
// live: [{ address, workspace, class, title, pid, floating, fullscreen,
//          fullscreenClient }]
//
// Rules, in order of trust:
//   * a window that is live on the park workspace is always recoverable;
//   * a journal entry whose window is live elsewhere is dropped (someone
//     already moved it back);
//   * a journal entry with no live window becomes a Reopen only when the
//     class is allowlisted, otherwise it is discarded;
//   * a live parked window nobody remembers is exposed as "recovered".
function reconcile(state, journalEntries, live, journalSequence) {
  var base = cloneState(state)
  var park = base.parkWorkspace
  var liveByAddr = {}
  for (var i = 0; i < (live || []).length; i++) {
    var w = live[i]
    var addr = normalizeAddress(w && w.address)
    if (addr) liveByAddr[addr] = w
  }

  var report = { recovered: [], converted: [], dropped: [], kept: [] }
  var byAddress = {}
  var merged = []

  function consider(action, source) {
    if (!action) return
    if (action.type !== "park") {
      merged.push(action)
      return
    }
    if (byAddress[action.address]) return
    var lw = liveByAddr[action.address]
    if (lw && String(lw.workspace || "") === park) {
      byAddress[action.address] = true
      var refreshed = Object.assign({}, action)
      if (lw.title) refreshed.label = shortLabel({ title: lw.title, class: action.class || lw.class })
      if (!refreshed.class && lw.class) refreshed.class = sanitizeClass(lw.class)
      merged.push(refreshed)
      report.kept.push(action.address)
      return
    }
    if (lw) {
      // Live, but visible somewhere else: nothing to recover.
      report.dropped.push(action.address)
      return
    }
    if (relaunchCommand(action)) {
      var re = relaunchAction(action, action.sequence)
      re.address = ""
      merged.push(re)
      report.converted.push(action.address)
      return
    }
    report.dropped.push(action.address)
  }

  for (var u = 0; u < base.undo.length; u++) consider(base.undo[u], "state")
  for (var j = 0; j < (journalEntries || []).length; j++) {
    var e = journalEntries[j]
    consider(parkAction(e, e.sequence), "journal")
  }

  var seq = Math.max(base.sequence, clampInt(journalSequence, 0, 2147483647, 0))
  for (var m = 0; m < merged.length; m++) seq = Math.max(seq, Number(merged[m].sequence || 0))

  for (var addr2 in liveByAddr) {
    if (byAddress[addr2]) continue
    var lw2 = liveByAddr[addr2]
    if (String(lw2.workspace || "") !== park) continue
    seq += 1
    var stranded = parkAction({
      address: addr2,
      workspace: "",
      class: lw2.class || "",
      title: lw2.title || "",
      pid: lw2.pid || 0,
      floating: !!lw2.floating,
      fullscreen: 0,
      fullscreenClient: 0,
      recovered: true
    }, seq)
    if (!stranded.class) stranded.class = "window"
    byAddress[addr2] = true
    merged.push(stranded)
    report.recovered.push(addr2)
  }

  merged.sort(function (a, b) { return Number(a.sequence || 0) - Number(b.sequence || 0) })

  // Redo entries pointing at windows that no longer exist are noise.
  var redo = base.redo.filter(function (a) {
    if (!a || a.type !== "park") return !!a
    return !!liveByAddr[a.address]
  })

  var next = cloneState(base)
  next.undo = merged
  next.redo = redo
  next.sequence = seq
  // Over capacity after recovery means the compositor holds more hidden
  // windows than policy allows; expose them anyway rather than closing
  // anything during startup. capUndo() only runs on new parks.
  return { state: next, report: report }
}

if (typeof module !== "undefined") {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID,
    PARK_WORKSPACE: PARK_WORKSPACE,
    DEFAULT_MAX: DEFAULT_MAX,
    JOURNAL_SCHEMA: JOURNAL_SCHEMA,
    JOURNAL_MAX_BYTES: JOURNAL_MAX_BYTES,
    JOURNAL_MAX_ENTRIES: JOURNAL_MAX_ENTRIES,
    defaultExcludedClasses: defaultExcludedClasses,
    clampMax: clampMax,
    createState: createState,
    cloneState: cloneState,
    normalizeAddress: normalizeAddress,
    normalizeWorkspace: normalizeWorkspace,
    isSpecialWorkspace: isSpecialWorkspace,
    canPark: canPark,
    canRelaunch: canRelaunch,
    sanitizeLabel: sanitizeLabel,
    sanitizeClass: sanitizeClass,
    sanitizeMedia: sanitizeMedia,
    shortLabel: shortLabel,
    toastLabel: toastLabel,
    pushPark: pushPark,
    pushRelaunch: pushRelaunch,
    pushRecovered: pushRecovered,
    undo: undo,
    undoAt: undoAt,
    redo: redo,
    undoEffects: undoEffects,
    attachMedia: attachMedia,
    parkedAddresses: parkedAddresses,
    findParked: findParked,
    dropAddress: dropAddress,
    markDead: markDead,
    luaString: luaString,
    relaunchCommand: relaunchCommand,
    restoreAll: restoreAll,
    clear: clear,
    reset: reset,
    statusSummary: statusSummary,
    toJournal: toJournal,
    parseJournal: parseJournal,
    reconcile: reconcile
  }
}
