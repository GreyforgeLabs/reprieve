import QtQuick

// Reprieve product mark: a halo over swept angel wings in cyan and electric
// blue. Fixed brand artwork — unlike GreyforgeMark it does not recolor with
// the theme, so state (attention, parked count, pulse) is carried by the
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
//   artOpacity — for dimmed states (empty timeline, idle)
Item {
  id: root

  property real size: 32
  property color surface: "#0b0f14"
  property string variant: "auto"
  property bool compact: size <= 24
  property color dot: "#fda52b"
  property bool showDot: false
  property real artOpacity: 1.0

  width: size
  height: size

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

  Image {
    id: art
    anchors.fill: parent
    source: root.art
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: true
    opacity: root.artOpacity
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
