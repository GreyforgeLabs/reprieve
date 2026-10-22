import QtQuick
import QtQuick.Effects

// Reprieve product mark: a halo over swept angel wings in cyan and electric
// blue. The default artwork is fixed brand art; `tint` and `halo` let a caller
// repaint the wings and halo in theme colours (the bar widget uses the bar
// foreground plus the accent for its two-tone mode). State is carried by the
// caller's overlays, and legibility on light surfaces comes from the
// light-surface variant, picked automatically from `surface` unless
// `variant` is set explicitly.
//
//   size     — outer square; the artwork is square with transparency
//   surface  — background the mark sits on (auto-picks the variant)
//   variant  — "auto" | "dark" | "light" (light = deeper art for pale bars)
//   compact  — simplified geometry; defaults on at taskbar sizes (<= 24)
//   dot      — optional status dot colour ("" = none), drawn bottom-left so
//              it never collides with the count badge callers put bottom-right
//   showDot  — dot visibility switch
//   tint     — optional flat colour for the wings (transparent = brand art);
//              callers use it to follow the bar foreground like every other
//              widget glyph
//   halo     — optional flat colour for the halo, so the mark can stay
//              two-tone; defaults to `tint` for a single-colour mark
//   artOpacity — for dimmed states (empty timeline, idle)
Item {
  id: root

  property real size: 32
  property color surface: "#0b0f14"
  property string variant: "auto"
  property bool compact: size <= 24
  property color dot: "#fda52b"
  property bool showDot: false
  property color tint: "transparent"
  property color halo: tint
  property real artOpacity: 1.0

  width: size
  height: size

  readonly property bool tinted: tint.a > 0
  readonly property bool haloShown: tinted && halo.a > 0

  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  readonly property bool onLight: {
    if (variant === "light") return true
    if (variant === "dark") return false
    return luminance(surface) > 0.6
  }

  readonly property string art: {
    if (onLight) return "icons/reprieve-angel-light-surface.svg"
    return compact ? "icons/reprieve-angel-compact.svg" : "icons/reprieve-angel.svg"
  }

  // Brand artwork (multi-colour): shown as-is unless a flat tint is asked for.
  Image {
    id: brandArt
    anchors.fill: parent
    source: root.art
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: true
    opacity: root.artOpacity
    visible: !root.tinted
  }

  // Flat masks, painted by MultiEffect. Their layers stay enabled so a live
  // colour-mode switch has a texture ready; toggling layer.enabled on a newly
  // created widget can otherwise leave the mark blank until a reload.
  Image {
    id: bodyMask
    anchors.fill: parent
    source: "icons/reprieve-angel-mask.svg"
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: false
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: bodyMask
    source: bodyMask
    visible: root.tinted
    opacity: root.artOpacity
    colorization: 1.0
    colorizationColor: root.tint
  }

  // The halo rides on top of the wings so it can carry the second colour.
  Image {
    id: haloMask
    anchors.fill: parent
    source: "icons/reprieve-angel-halo-mask.svg"
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: false
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: haloMask
    source: haloMask
    visible: root.haloShown
    opacity: root.artOpacity
    colorization: 1.0
    colorizationColor: root.halo
  }

  Rectangle {
    visible: root.showDot
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.leftMargin: Math.max(0, root.size * 0.02)
    anchors.bottomMargin: Math.max(0, root.size * 0.04)
    width: Math.max(3, root.size * 0.26)
    height: width
    radius: width / 2
    color: root.dot
    border.width: 1
    border.color: root.surface
  }
}
