import QtQuick

// A keyboard hint rendered as a keycap chip followed by its meaning:
//   [Enter] restore
// Keeps the hint line scannable instead of a run-on sentence.
Row {
  id: root

  property string key: ""
  property string label: ""
  property color foreground: "#cacccc"
  property string fontFamily: "monospace"
  property real fontSize: 10
  property bool emphasis: false

  spacing: Math.round(fontSize * 0.45)

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: keyText.implicitWidth + Math.round(root.fontSize * 0.9)
    height: keyText.implicitHeight + Math.round(root.fontSize * 0.35)
    radius: Math.max(3, Math.round(root.fontSize * 0.35))
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.emphasis ? 0.18 : 0.08)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.emphasis ? 0.45 : 0.22)

    Text {
      id: keyText
      anchors.centerIn: parent
      text: root.key
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.bold: true
      renderType: Text.NativeRendering
    }
  }

  Text {
    anchors.verticalCenter: parent.verticalCenter
    visible: root.label !== ""
    text: root.label
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.62
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    renderType: Text.NativeRendering
  }
}
