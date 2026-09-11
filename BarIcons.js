// Best-effort app icon for a parked window, from its Hyprland class only.
// Never touches argv or the process. Returns "" when nothing sensible exists
// so the widget can draw a glyph instead.
.pragma library

var cache = ({})

function candidates(klass) {
  var out = []
  var k = String(klass || "")
  if (!k) return out
  out.push(k)
  var lower = k.toLowerCase()
  if (lower !== k) out.push(lower)
  // Omarchy / Chrome web apps: chrome-<host>__-Default → the host name is the
  // .desktop id Omarchy generates, and often the icon name as well.
  var pwa = k.match(/^(?:chrome|chromium|brave|google-chrome)-([A-Za-z0-9._-]+)__-Default$/i)
  if (pwa) {
    var host = pwa[1].replace(/_/g, ".")
    out.push(host)
    var parts = host.split(".")
    if (parts.length >= 2) out.push(parts[parts.length - 2])
  }
  // Reverse-DNS classes: try the last component too (org.gnome.Nautilus → nautilus).
  if (k.indexOf(".") !== -1 && !pwa) {
    var tail = k.split(".").pop()
    if (tail) { out.push(tail); out.push(tail.toLowerCase()) }
  }
  // Browsers report class without the -stable suffix their desktop file uses.
  if (lower === "google-chrome") out.push("google-chrome-stable")
  if (lower === "brave-browser") out.push("brave-browser")
  return out
}

function usable(path) {
  return !!path && String(path).length > 0 && String(path).indexOf("application-x-executable") === -1
}

// qs / entries are the Quickshell and DesktopEntries singletons, passed in by
// the widget so this file stays a plain library.
function resolve(klass, qs, entries) {
  var key = String(klass || "")
  if (!key) return ""
  if (cache[key] !== undefined) return cache[key]
  var found = ""
  var list = candidates(key)
  for (var i = 0; i < list.length && !found; i++) {
    var name = list[i]
    try {
      var entry = entries ? entries.heuristicLookup(name) : null
      if (entry && entry.icon) {
        var p = qs.iconPath(String(entry.icon), true)
        if (usable(p)) { found = p; break }
      }
    } catch (e) {}
    try {
      var direct = qs.iconPath(name, true)
      if (usable(direct)) { found = direct; break }
    } catch (e2) {}
  }
  cache[key] = found
  return found
}

function forget() { cache = ({}) }
