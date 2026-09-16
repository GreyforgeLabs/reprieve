import QtQuick

// "GREYFORGE LABS" set in the brand's letter-spaced caps, led by the mark.
// Used as the signature line of every Reprieve surface.
Row {
  id: root

  property color foreground: "#cacccc"
  property color plate: "#0d1116"
  property string fontFamily: "monospace"
  property real fontSize: 10
  property real markSize: Math.round(fontSize * 1.5)
  property real labelOpacity: 0.72
  property string text: "GREYFORGE LABS"

  spacing: Math.round(fontSize * 0.6)

  GreyforgeMark {
    anchors.verticalCenter: parent.verticalCenter
    size: root.markSize
    steel: root.foreground
    plate: root.plate
    coreScale: 0.26
  }

  Text {
    anchors.verticalCenter: parent.verticalCenter
    text: root.text
    textFormat: Text.PlainText
    color: root.foreground
    opacity: root.labelOpacity
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: true
    font.letterSpacing: Math.max(1, root.fontSize * 0.22)
    renderType: Text.NativeRendering
  }
}
