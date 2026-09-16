import QtQuick

// The Greyforge Labs mark: a bevelled steel hexagon with cyan structural
// seams and a single warm amber core, drawn on a Canvas so it scales to any
// size without an asset. The steel takes its tone from `steel` (normally
// the surface foreground) so the mark sits in every Omarchy theme, while
// the cyan seams and the amber core are fixed brand colours.
//
//   size     — outer diameter of the hexagon
//   steel    — tone of the machined ring (theme foreground)
//   plate    — colour of the inset face (theme background)
//   core     — amber by default; pass the theme urgent colour for alerts
//   coreScale— relative size of the core dot
//   seams    — draw the cyan corner seams
//   emblem   — optional child content drawn centred inside the inset
Item {
  id: root

  property real size: 32
  property color steel: "#aab3bc"
  property color plate: "#0d1116"
  property color core: "#fda52b"
  property color seam: "#38c8e8"
  property real coreScale: 0.22
  property bool seams: true
  property bool showCore: true
  property real ringScale: 1.0
  property real opacityRing: 1.0

  width: size
  height: size
  default property alias emblem: emblemHolder.data

  onSteelChanged: canvas.requestPaint()
  onPlateChanged: canvas.requestPaint()
  onCoreChanged: canvas.requestPaint()
  onSeamChanged: canvas.requestPaint()
  onCoreScaleChanged: canvas.requestPaint()
  onSeamsChanged: canvas.requestPaint()
  onShowCoreChanged: canvas.requestPaint()
  onSizeChanged: canvas.requestPaint()

  function hex(ctx, cx, cy, r) {
    ctx.beginPath()
    for (var i = 0; i < 6; i++) {
      var a = Math.PI / 6 + i * Math.PI / 3
      var x = cx + r * Math.cos(a), y = cy + r * Math.sin(a)
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
    }
    ctx.closePath()
  }

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.clearRect(0, 0, w, h)
      var cx = w / 2, cy = h / 2
      var r = Math.min(w, h) / 2 * root.ringScale
      var s = root.steel
      var lighter = Qt.lighter(s, 1.35)
      var darker = Qt.darker(s, 1.9)

      // outer bevel: light top-left, dark bottom-right
      var edge = ctx.createLinearGradient(cx - r, cy - r, cx + r, cy + r)
      edge.addColorStop(0, rgba(lighter, root.opacityRing))
      edge.addColorStop(0.5, rgba(s, root.opacityRing))
      edge.addColorStop(1, rgba(darker, root.opacityRing))
      ctx.fillStyle = edge
      root.hex(ctx, cx, cy, r)
      ctx.fill()

      // machined face
      var face = ctx.createLinearGradient(cx - r, cy - r, cx + r, cy + r)
      face.addColorStop(0, rgba(Qt.darker(s, 1.45), root.opacityRing))
      face.addColorStop(0.5, rgba(Qt.darker(s, 2.1), root.opacityRing))
      face.addColorStop(1, rgba(Qt.darker(s, 3.2), root.opacityRing))
      ctx.fillStyle = face
      root.hex(ctx, cx, cy, r * 0.86)
      ctx.fill()

      // inset plate
      var inset = ctx.createLinearGradient(cx, cy - r, cx, cy + r)
      inset.addColorStop(0, rgba(root.plate, 1))
      inset.addColorStop(1, rgba(Qt.lighter(root.plate, 1.6), 1))
      ctx.fillStyle = inset
      root.hex(ctx, cx, cy, r * 0.70)
      ctx.fill()

      // cyan seams at the six bevel corners
      if (root.seams) {
        ctx.strokeStyle = rgba(root.seam, 0.9)
        ctx.lineWidth = Math.max(1, r * 0.06)
        ctx.lineCap = "round"
        for (var i = 0; i < 6; i++) {
          var a = Math.PI / 6 + i * Math.PI / 3
          ctx.beginPath()
          ctx.moveTo(cx + r * 0.86 * Math.cos(a), cy + r * 0.86 * Math.sin(a))
          ctx.lineTo(cx + r * 0.70 * Math.cos(a), cy + r * 0.70 * Math.sin(a))
          ctx.stroke()
        }
      }

      // amber core with a soft halo
      if (root.showCore) {
        var cr = r * root.coreScale
        var halo = ctx.createRadialGradient(cx, cy, 0, cx, cy, cr * 2.4)
        halo.addColorStop(0, rgba(root.core, 0.55))
        halo.addColorStop(1, rgba(root.core, 0))
        ctx.fillStyle = halo
        ctx.beginPath(); ctx.arc(cx, cy, cr * 2.4, 0, Math.PI * 2); ctx.fill()
        var dot = ctx.createRadialGradient(cx - cr * 0.3, cy - cr * 0.3, 0, cx, cy, cr)
        dot.addColorStop(0, "#fff1cc")
        dot.addColorStop(0.6, rgba(root.core, 1))
        dot.addColorStop(1, rgba(Qt.darker(root.core, 1.3), 1))
        ctx.fillStyle = dot
        ctx.beginPath(); ctx.arc(cx, cy, cr, 0, Math.PI * 2); ctx.fill()
      }
    }
  }

  Item {
    id: emblemHolder
    anchors.centerIn: parent
    width: root.size * 0.62
    height: width
  }
}
