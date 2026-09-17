import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "ReprieveModel.js" as Model

// Flight: the park/restore effect. A snapshot of the window glides into the
// Reprieve bar mark when it is parked and glides back out when it is
// restored ("subtle"); in "angel" mode a winged light swoops down from the
// mark first, lifts the window and carries it home, and brings it back the
// same way.
//
// The service owns the real move. Each job carries a token; the scene
// calls service.flightCut(token) at the exact frame the real window should
// vanish (park) or appear (restore), so the snapshot and the window hand
// over without a gap. Scenes are created on demand on a transparent,
// input-transparent overlay layer of the window's screen and destroyed
// when the flight ends, so an idle shell draws nothing.
//
// The park frame (a ScreencopyView holding one frame of the window) is
// kept per address in a hidden vault, with the window's place on screen,
// and flown back by the restore flight. Nothing is persisted; after a
// shell restart a restore is a plain cut.
Item {
  id: root

  property var service: null
  readonly property color brandAmber: "#fda52b"
  readonly property color brandCyan: "#38c8e8"

  // address -> { view, rect, screen }
  property var memory: ({})
  property var containers: ({})   // screen name -> scene container item
  property int activeCount: 0
  property int flown: 0           // flights completed since the shell started

  onServiceChanged: if (service) service.flightHandler = root
  Component.onCompleted: if (service) service.flightHandler = root

  // ---- handler API, called by the service

  function wants(job) {
    return !!(job && job.screen && root.containers[job.screen])
  }

  function remembered(address) {
    var m = root.memory[String(address)]
    return m ? { rect: m.rect, screen: m.screen } : null
  }

  function remember(address, entry) {
    var next = {}
    for (var k in root.memory) next[k] = root.memory[k]
    next[String(address)] = entry
    root.memory = next
  }

  function forget(address) {
    var next = {}
    var gone = root.memory[String(address)]
    for (var k in root.memory) if (k !== String(address)) next[k] = root.memory[k]
    root.memory = next
    if (gone && gone.view) gone.view.destroy()
  }

  // One frame of a live window, owned by the vault so it outlives the
  // scene that captured it.
  Component {
    id: frameComponent
    ScreencopyView {
      live: false
      paintCursor: false
    }
  }

  function anchorFor(screen) {
    var a = service && service.barAnchors ? service.barAnchors[String(screen)] : null
    return a || null
  }

  function launch(job) {
    var container = root.containers[job.screen]
    if (!container) { if (service) service.flightCut(job.token); return }
    var view = null
    if (job.kind === "park") {
      root.forget(job.address)
      var src = job.handle && job.handle.wayland ? job.handle.wayland : null
      if (src) view = frameComponent.createObject(container.vault, { captureSource: src, width: job.rect.w, height: job.rect.h, constraintSize: Qt.size(job.rect.w, job.rect.h) })
    } else {
      var m = root.memory[job.address]
      view = m ? m.view : null
    }
    var scene = sceneComponent.createObject(container, { job: job, frame: view })
    if (!scene) { if (service) service.flightCut(job.token); return }
    root.activeCount++
  }

  function sceneDone(scene) {
    root.activeCount = Math.max(0, root.activeCount - 1)
    root.flown++
    scene.destroy()
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onFlightPark(job) { root.launch(job) }
    function onFlightRestore(job) { root.launch(job) }
  }

  // Drop frames of windows the timeline no longer holds on either stack
  // (a restore moves the entry to redo before the flight asks for its
  // frame, so both count). Deferred so an in-flight restore reads first.
  function prune() {
    if (!root.service) return
    var keep = {}
    var lists = [root.service.undoStack || [], root.service.redoStack || []]
    for (var l = 0; l < 2; l++) for (var i = 0; i < lists[l].length; i++) if (lists[l][i] && lists[l][i].address) keep[lists[l][i].address] = true
    for (var k in root.memory) if (!keep[k]) root.forget(k)
  }
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onUndoStackChanged() { Qt.callLater(root.prune) }
    function onRedoStackChanged() { Qt.callLater(root.prune) }
  }

  // One overlay per screen, mapped only while a flight is in the air.
  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      id: layer
      required property var modelData
      screen: modelData
      // mapped only while a scene is in the air (the vault is always there)
      visible: stage.children.length > 1
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "reprieve-flight"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      Item {
        id: stage
        anchors.fill: parent
        readonly property string screenName: layer.modelData ? String(layer.modelData.name) : ""
        // the layer takes a frame or two to map; scenes wait for it
        readonly property bool mapped: layer.backingWindowVisible === true
        // parked frames wait here between flights
        property Item vault: Item { parent: stage; visible: false; z: -1 }
        function register() {
          if (!screenName) return
          var next = {}
          for (var k in root.containers) next[k] = root.containers[k]
          next[screenName] = stage
          root.containers = next
        }
        Component.onCompleted: register()
        onScreenNameChanged: register()
        Component.onDestruction: {
          var next = {}
          for (var k in root.containers) if (k !== screenName) next[k] = root.containers[k]
          root.containers = next
        }
      }
    }
  }

  // ------------------------------------------------------------- the scene

  Component {
    id: sceneComponent

    Item {
      id: scene
      anchors.fill: parent

      required property var job
      property var frame: null      // the window's ScreencopyView (vault-owned)
      readonly property bool park: job.kind === "park"
      readonly property bool angel: job.mode === "angel"
      readonly property var rect: job.rect
      readonly property var anchor: root.anchorFor(job.screen)
      // Where the mark is; without a published anchor, the top-right of the
      // screen (the bar's default right section).
      readonly property real ax: anchor ? anchor.x : width - 48
      readonly property real ay: anchor ? anchor.y : 14
      readonly property real markSize: anchor && anchor.size > 0 ? anchor.size : 22
      // The grab point: a little below the window's top edge, centred.
      readonly property real gx: rect.x + rect.w / 2
      readonly property real gy: rect.y + Math.min(rect.h * 0.18, 60)
      readonly property real cx: rect.x + rect.w / 2
      readonly property real cy: rect.y + rect.h / 2

      property real t: 0
      property bool cutDone: false
      property bool captured: false
      readonly property bool hasImage: !!frame
      property var trail: []

      // Timeline (fractions of one flight). Restore is park in reverse.
      //   park/angel:     swoop 0-.36 · lift .36-.5 (cut at .36) · carry .5-1 · land
      //   restore/angel:  rise+descend 0-.57 · settle .57-.7 (cut at .7) · return .7-1 · land
      //   park/subtle:    settle 0-.1 (cut at .1) · glide .1-1
      //   restore/subtle: glide 0-1 (cut at 1)
      readonly property int duration: angel ? 1000 : (park ? 540 : 520)
      readonly property real cutAt: angel ? (park ? 0.36 : 0.7) : (park ? 0.1 : 1)
      // how far the window lifts while she holds it, and how far she hovers
      // above its top edge
      readonly property real liftPx: 10
      readonly property real hoverPx: 20
      readonly property real minScale: Math.max(0.05, (markSize * 0.9) / Math.max(rect.w, rect.h))

      function ease(x) { x = Math.max(0, Math.min(1, x)); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2 }
      function easeOut(x) { x = Math.max(0, Math.min(1, x)); return 1 - Math.pow(1 - x, 3) }
      function easeIn(x) { x = Math.max(0, Math.min(1, x)); return x * x * x }
      function span(a, b) { return Math.max(0, Math.min(1, (t - a) / (b - a))) }

      // Quadratic curve between the mark and a point with a sideways bow so
      // the path reads as a swoop, not a slide. Always parameterised from
      // the mark (u = 0) to the point (u = 1); the way back is 1 - u, so
      // park and restore share the same line.
      function curve(x1, y1, u) {
        var x0 = ax, y0 = ay
        var mx = (x0 + x1) / 2, my = (y0 + y1) / 2
        var dx = x1 - x0, dy = y1 - y0
        var len = Math.max(1, Math.sqrt(dx * dx + dy * dy))
        var bow = Math.min(len * 0.28, 220)
        var px = -dy / len, py = dx / len
        if (mx + px * bow < 0 || mx + px * bow > scene.width) { px = -px; py = -py }
        var qx = mx + px * bow, qy = my + py * bow
        var v = 1 - u
        return { x: v * v * x0 + 2 * v * u * qx + u * u * x1, y: v * v * y0 + 2 * v * u * qy + u * u * y1 }
      }
      // the two lines: mark <-> the window's centre (carry), and mark <-> her
      // hover point above the window (swoop)
      function carryPath(u) { return curve(cx, cy - liftPx, u) }
      function swoopPath(u) { return curve(cx, rect.y - hoverPx, u) }

      // ---- positions as functions of t

      // The snapshot's centre, scale and opacity.
      readonly property var snap: {
        var s = 1, p = { x: cx, y: cy }, o = 1
        if (park) {
          if (angel) {
            if (t < 0.36) { o = 0 }
            else if (t < 0.5) { var l = ease(span(0.36, 0.5)); s = 1 - 0.06 * l; p = { x: cx, y: cy - liftPx * l } }
            else { var u = ease(span(0.5, 1)); p = carryPath(1 - u); s = 0.94 + (minScale - 0.94) * u; o = 1 - easeIn(span(0.88, 1)) }
          } else {
            if (t < 0.1) { o = 0 }
            else { var u2 = ease(span(0.1, 1)); p = curve(cx, cy, 1 - u2); s = 1 + (minScale - 1) * u2; o = 1 - easeIn(span(0.85, 1)) }
          }
        } else {
          if (angel) {
            if (t < 0.57) { var u3 = ease(span(0, 0.57)); p = carryPath(u3); s = minScale + (0.94 - minScale) * u3; o = easeOut(span(0, 0.12)) }
            else if (t < 0.7) { var l2 = ease(span(0.57, 0.7)); s = 0.94 + 0.06 * l2; p = { x: cx, y: cy - liftPx * (1 - l2) } }
            else { o = 0 }
          } else {
            var u4 = ease(t); p = curve(cx, cy, u4); s = minScale + (1 - minScale) * u4; o = cutDone ? 0 : easeOut(span(0, 0.15))
          }
        }
        return { x: p.x, y: p.y, s: s, o: o }
      }

      // She hovers a fixed distance above the window's top edge while she
      // holds it, so every phase hands over without a jump.
      function above(p, s) { return { x: p.x, y: p.y - s * rect.h / 2 - hoverPx } }

      // The angel's position and opacity.
      readonly property var wing: {
        var p = { x: ax, y: ay }, o = 0
        if (!angel) return { x: p.x, y: p.y, o: 0 }
        if (park) {
          if (t < 0.36) { var u = ease(span(0, 0.36)); p = swoopPath(u); o = easeOut(span(0, 0.1)) }
          else if (t < 0.5) { p = above({ x: snap.x, y: snap.y }, snap.s) }
          else { p = above({ x: snap.x, y: snap.y }, snap.s); o = 1 - easeIn(span(0.88, 1)) }
        } else {
          if (t < 0.7) { p = above({ x: snap.x, y: snap.y }, snap.s); o = easeOut(span(0, 0.12)) }
          else { var u2 = ease(span(0.7, 1)); p = swoopPath(1 - u2); o = 1 - easeIn(span(0.88, 1)) }
        }
        return { x: p.x, y: p.y, o: o }
      }

      // ---- lifecycle

      function cut() {
        if (cutDone) return
        cutDone = true
        if (root.service) root.service.flightCut(job.token)
      }

      function finish() {
        cut()
        if ((park || angel) && root.service) root.service.flightLanded(job.address)
        root.sceneDone(scene)
      }

      // The timeline runs only once the overlay layer is on screen; until
      // then the real window stays put (no cut has happened yet).
      property bool wantFlight: false
      readonly property bool stageMapped: parent && parent.mapped === true
      function startFlight() {
        wantFlight = true
        if (stageMapped) mapSettle.start()
      }
      onStageMappedChanged: if (stageMapped && wantFlight && !flight.running) mapSettle.start()
      Timer { id: mapSettle; interval: 32; repeat: false; onTriggered: if (!flight.running && scene.t === 0) flight.start() }

      onTChanged: {
        if (!cutDone && t >= cutAt) cut()
        if (angel) {
          var tr = trail.slice(-14)
          tr.push({ x: wing.x, y: wing.y, o: wing.o })
          trail = tr
          angelCanvas.requestPaint()
        }
      }

      NumberAnimation on t { id: flight; from: 0; to: 1; duration: scene.duration; running: false; onFinished: scene.finish() }

      // Park: grab one frame of the live window before it goes. The
      // ScreencopyView is the flying item itself; a reduced copy is kept
      // for the restore. If no frame arrives in time the ghost flies alone.
      Component.onCompleted: {
        if (frame) { frame.parent = ghost; frame.anchors.fill = ghost; frame.visible = true }
        if (park) {
          if (frame && frame.hasContent) { captured = true; startFlight() }
          else captureTimeout.start()
        } else startFlight()
      }
      Component.onDestruction: {
        if (!frame) return
        var container = root.containers[job.screen]
        if (park && container) {
          frame.anchors.fill = undefined
          frame.parent = container.vault
          root.remember(job.address, { view: frame, rect: rect, screen: job.screen })
        } else {
          root.forget(job.address)
        }
      }
      Connections {
        target: scene.frame
        ignoreUnknownSignals: true
        function onHasContentChanged() {
          if (!scene.park || scene.captured || !scene.frame.hasContent) return
          scene.captured = true
          captureTimeout.stop()
          scene.startFlight()
        }
      }
      Timer { id: captureTimeout; interval: 140; repeat: false; onTriggered: if (!scene.captured) { console.warn("reprieve: flight got no frame for", scene.job.address); scene.captured = true; scene.startFlight() } }

      // ---- the window in flight

      Item {
        id: ghost
        x: scene.snap.x - width / 2
        y: scene.snap.y - height / 2
        width: scene.rect.w
        height: scene.rect.h
        scale: scene.snap.s
        opacity: scene.snap.o
        transformOrigin: Item.Center
        // opacity 0 (not visible: false) hides it before the cut, so the
        // frame inside keeps capturing

        // steel plate under the snapshot, cyan seam around it
        Rectangle {
          anchors.fill: parent
          anchors.margins: -2
          radius: 6
          color: Qt.rgba(0.06, 0.07, 0.09, scene.hasImage ? 0.9 : 0.35)
          border.width: 2
          border.color: Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.85)
        }
        Rectangle {
          anchors.fill: parent
          anchors.margins: -8
          radius: 12
          color: "transparent"
          border.width: 6
          border.color: Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.18)
        }

      }

      // ---- the winged light

      Repeater {
        model: scene.angel ? scene.trail.length : 0
        Rectangle {
          required property int index
          readonly property var pt: scene.trail[index]
          readonly property real k: (index + 1) / scene.trail.length
          x: pt.x - width / 2
          y: pt.y - height / 2
          width: 6 + 14 * k
          height: width
          radius: width / 2
          color: Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.22 * k * pt.o)
        }
      }

      Canvas {
        id: angelCanvas
        visible: scene.angel
        width: 220
        height: 160
        x: scene.wing.x - width / 2
        y: scene.wing.y - height / 2
        opacity: scene.wing.o
        antialiasing: true
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var cx = width / 2, cy = height / 2
          var tr = scene.trail
          // heading from the last two trail points
          var hx = 1, hy = 0
          if (tr.length >= 2) { var a = tr[tr.length - 2], b = tr[tr.length - 1]; var dx = b.x - a.x, dy = b.y - a.y; var l = Math.sqrt(dx * dx + dy * dy); if (l > 0.5) { hx = dx / l; hy = dy / l } }
          var speed = tr.length >= 2 ? Math.min(1, Math.hypot(tr[tr.length - 1].x - tr[tr.length - 2].x, tr[tr.length - 1].y - tr[tr.length - 2].y) / 18) : 0
          var flap = Math.sin(scene.t * Math.PI * 2 * 5) * (0.35 + 0.35 * speed)
          var cyan = root.brandCyan, amber = root.brandAmber

          function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }

          // body glow
          var glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, 30)
          glow.addColorStop(0, rgba(cyan, 0.45))
          glow.addColorStop(0.5, rgba(cyan, 0.12))
          glow.addColorStop(1, rgba(cyan, 0))
          ctx.fillStyle = glow
          ctx.beginPath(); ctx.arc(cx, cy, 30, 0, Math.PI * 2); ctx.fill()

          // wings: a faint membrane and four feather strokes each side,
          // lifted by the flap; tilted a little into the heading
          ctx.save()
          ctx.translate(cx, cy)
          ctx.rotate(hx * 0.18)
          ctx.lineCap = "round"
          for (var side = -1; side <= 1; side += 2) {
            var span = 74, liftTop = -40 * (1 - flap * 0.6)
            // membrane
            var mg = ctx.createLinearGradient(0, 0, side * span, 0)
            mg.addColorStop(0, "rgba(255,255,255,0.22)")
            mg.addColorStop(0.5, rgba(cyan, 0.16))
            mg.addColorStop(1, rgba(cyan, 0))
            ctx.fillStyle = mg
            ctx.beginPath()
            ctx.moveTo(side * 2, 0)
            ctx.bezierCurveTo(side * span * 0.3, liftTop - 10, side * span * 0.8, liftTop + 4, side * span, liftTop + 30)
            ctx.bezierCurveTo(side * span * 0.7, 16, side * span * 0.3, 14, side * 2, 8)
            ctx.closePath()
            ctx.fill()
            for (var f = 0; f < 4; f++) {
              var len = span - f * 12
              var lift = liftTop + f * 12
              var tipX = side * len, tipY = lift + 30 - f * 4
              var c1X = side * len * 0.3, c1Y = liftTop - 14 + f * 6
              var c2X = side * len * 0.8, c2Y = lift
              var g = ctx.createLinearGradient(0, 0, tipX, tipY)
              g.addColorStop(0, "rgba(255,255,255,0.98)")
              g.addColorStop(0.4, rgba(cyan, 0.95))
              g.addColorStop(1, rgba(cyan, 0))
              ctx.strokeStyle = g
              ctx.lineWidth = 4.2 - f * 0.8
              ctx.beginPath()
              ctx.moveTo(side * 3, -2 + f * 3)
              ctx.bezierCurveTo(c1X, c1Y, c2X, c2Y, tipX, tipY)
              ctx.stroke()
            }
          }
          ctx.restore()

          // body: a bright teardrop with a white core
          var body = ctx.createRadialGradient(cx, cy - 2, 0, cx, cy, 12)
          body.addColorStop(0, "rgba(255,255,255,1)")
          body.addColorStop(0.45, rgba(cyan, 0.95))
          body.addColorStop(1, rgba(cyan, 0))
          ctx.fillStyle = body
          ctx.beginPath(); ctx.arc(cx, cy, 12, 0, Math.PI * 2); ctx.fill()

          // halo: amber ring floating above the body
          var haloY = cy - 28 + Math.sin(scene.t * Math.PI * 2 * 2.5) * 1.5
          var hg = ctx.createRadialGradient(cx, haloY, 4, cx, haloY, 16)
          hg.addColorStop(0, rgba(amber, 0))
          hg.addColorStop(0.55, rgba(amber, 0.35))
          hg.addColorStop(1, rgba(amber, 0))
          ctx.fillStyle = hg
          ctx.beginPath(); ctx.arc(cx, haloY, 16, 0, Math.PI * 2); ctx.fill()
          ctx.strokeStyle = rgba(amber, 0.95)
          ctx.lineWidth = 2
          ctx.lineWidth = 2.5
          ctx.beginPath(); ctx.ellipse(cx - 14, haloY - 4, 28, 8); ctx.stroke()
          ctx.strokeStyle = "rgba(255,244,214,0.9)"
          ctx.lineWidth = 1.2
          ctx.beginPath(); ctx.ellipse(cx - 11, haloY - 3, 22, 6); ctx.stroke()
        }
      }
    }
  }
}
