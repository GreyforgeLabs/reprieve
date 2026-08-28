import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "UndoModel.js" as UndoModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property int selectedIndex: 0
  property bool cursorActive: true

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(Style.space(48), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)

  readonly property var rows: {
    var undo = (service && service.undoStack) ? service.undoStack : []
    var out = []
    for (var i = undo.length - 1; i >= 0; i--) {
      var action = undo[i]
      if (!action) continue
      out.push({
        label: action.label || action.class || action.type,
        kind: action.type === "park" ? "Hidden" : "Relaunch",
        index: i
      })
    }
    return out
  }

  readonly property int redoCount: service ? Number(service.redoCount || 0) : 0

  function open(payloadJson) {
    root.opened = true
    root.selectedIndex = 0
    root.cursorActive = root.rows.length > 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.greyforgelabs.desktop-undo")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function select(delta) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.rows.length - 1 : 0
      return
    }
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next >= root.rows.length) next = root.rows.length - 1
    root.selectedIndex = next
  }

  function restoreSelected(here) {
    if (!service || root.rows.length === 0) return
    var row = root.rows[root.selectedIndex]
    if (!row) return
    service.restoreAt(row.index, here === true)
    if (!service.undoCount) {
      root.dismiss()
      return
    }
    if (root.selectedIndex >= root.rows.length)
      root.selectedIndex = Math.max(0, root.rows.length - 1)
  }

  function undoOnce() {
    root.restoreSelected(false)
  }

  function redoOnce() {
    if (!service) return
    service.redoLast()
    root.selectedIndex = 0
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-desktop-undo"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Z) {
            root.restoreSelected(!!(event.modifiers & Qt.ShiftModifier))
            event.accepted = true
          } else if (event.key === Qt.Key_Space || event.key === Qt.Key_H) {
            root.restoreSelected(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Y) {
            root.redoOnce()
            event.accepted = true
          } else if (event.key === Qt.Key_T) {
            if (service && service.toggleShowToast) service.toggleShowToast()
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        spacing: Style.spacing.md

        Text {
          text: "Tile Park and Undo"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          text: "Enter restore where it was  ·  Space restore here  ·  Y redo  ·  T toasts"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: list
          width: parent.width
          height: parent.height - Style.font.title - Style.font.caption * 2 - Style.spacing.md * 4 - Style.space(52)
          clip: true
          model: root.rows
          spacing: Style.spacing.xs
          currentIndex: root.selectedIndex
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: root.rowHeight
            radius: Math.max(6, Style.cornerRadius - 4)
            color: root.cursorActive && index === root.selectedIndex ? root.selectedBackground : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(72)
                text: modelData.kind
                color: root.cursorActive && index === root.selectedIndex ? root.selectedText : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(90)
                text: modelData.label
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.cursorActive && index === root.selectedIndex ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                root.selectedIndex = index
                root.cursorActive = true
                root.restoreSelected(false)
              }
            }
          }

          Text {
            visible: root.rows.length === 0
            anchors.centerIn: parent
            text: "Nothing to undo"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          text: {
            var counts = root.rows.length === 0
              ? (root.redoCount > 0 ? (root.redoCount + " redo waiting") : "Close a window with Super+W")
              : (root.rows.length + " undo  ·  " + root.redoCount + " redo")
            var pause = service && service.pauseMediaOnPark !== false ? "  ·  audio pauses on park" : ""
            return counts + pause
          }
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          width: parent.width
          height: Math.max(Style.space(36), Style.font.body + Style.spacing.md)
          radius: Math.max(6, Style.cornerRadius - 4)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            spacing: Style.spacing.md

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(72)
              text: "Toasts (top right)"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(56)
              horizontalAlignment: Text.AlignRight
              text: service && service.showToast !== false ? "On" : "Off"
              color: service && service.showToast !== false ? root.selectedText : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: if (service && service.toggleShowToast) service.toggleShowToast()
          }
        }
      }
    }
  }

  PanelWindow {
    id: toastPanel
    visible: !!(service && service.toastOpen && service.toastText)
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "omarchy-desktop-undo-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    Rectangle {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(44)
      anchors.rightMargin: Style.space(16)
      width: toastLabel.implicitWidth + Style.spacing.md * 2
      height: toastLabel.implicitHeight + Style.spacing.md
      radius: root.cornerRadius
      color: root.background
      border.width: Math.max(1, Style.space(1))
      border.color: root.border

      Text {
        id: toastLabel
        anchors.centerIn: parent
        text: service ? (service.toastText || "") : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
