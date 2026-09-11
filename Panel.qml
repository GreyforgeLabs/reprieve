import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ReprieveModel.js" as Model

// Reprieve overlay: the recovery timeline, the first-run setup card, and the
// small top-right toast. Colors and fonts come from the Omarchy theme.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string view: "timeline"
  property int selectedIndex: 0
  property bool cursorActive: true
  property string confirmAddress: ""
  property string setupMessage: ""
  // An auto-opened setup card grabs keyboard focus while the user may still
  // be typing. Keyboard consent is disarmed for a moment so a stray Enter
  // cannot install anything; a mouse click is always deliberate.
  property bool armed: false

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(460), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(Style.space(48), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property string pluginId: (manifest && manifest.id) || Model.PLUGIN_ID

  readonly property var rows: {
    var undo = (service && service.undoStack) ? service.undoStack : []
    var out = []
    for (var i = undo.length - 1; i >= 0; i--) {
      var action = undo[i]
      if (!action) continue
      var kind = action.type === "park" ? (action.recovered ? "Recovered" : "Parked") : "Reopen"
      out.push({
        label: action.label || action.class || action.type,
        kind: kind,
        index: i,
        address: action.address || "",
        live: action.type === "park",
        where: action.workspace ? ("workspace " + action.workspace) : (action.type === "park" ? "workspace unknown" : "")
      })
    }
    return out
  }

  readonly property int redoCount: service ? Number(service.redoCount || 0) : 0
  readonly property int parkedCount: service ? Number(service.parkedCount || 0) : 0
  readonly property bool needsSetup: !!service && service.bindsStatus !== null && !service.bindsInstalled
  readonly property var conflicts: (service && service.bindsStatus && service.bindsStatus.conflicts) ? service.bindsStatus.conflicts : []
  readonly property var installResult: service ? service.lastInstallResult : null

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    var requested = String(payload.view || "")
    if (requested === "setup") root.view = "setup"
    else if (requested === "timeline") root.view = "timeline"
    else root.view = root.needsSetup ? "setup" : "timeline"
    root.armed = String(payload.source || "") !== "auto"
    if (!root.armed) armTimer.restart()
    root.opened = true
    root.selectedIndex = 0
    root.confirmAddress = ""
    root.setupMessage = ""
    root.cursorActive = root.rows.length > 0
    if (service && service.refreshBindStatus) service.refreshBindStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function select(delta) {
    if (root.rows.length === 0) return
    root.confirmAddress = ""
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

  function currentRow() {
    if (root.rows.length === 0) return null
    return root.rows[Math.min(root.selectedIndex, root.rows.length - 1)] || null
  }

  function restoreSelected(here) {
    if (!service) return
    var row = root.currentRow()
    if (!row) return
    service.restoreAt(row.index, here === true)
    root.afterRowChange()
  }

  function afterRowChange() {
    root.confirmAddress = ""
    if (!service || !service.undoCount) { root.dismiss(); return }
    if (root.selectedIndex >= root.rows.length) root.selectedIndex = Math.max(0, root.rows.length - 1)
  }

  // Permanent close takes two presses of Delete (or two clicks) on the same
  // row so a stray key cannot destroy a live window.
  function closeSelected() {
    if (!service) return
    var row = root.currentRow()
    if (!row || !row.live || !row.address) return
    if (root.confirmAddress !== row.address) {
      root.confirmAddress = row.address
      confirmTimer.restart()
      return
    }
    service.closeParked(row.address)
    root.afterRowChange()
  }

  function restoreAll() {
    if (!service) return
    service.restoreAll()
    root.afterRowChange()
  }

  function redoOnce() {
    if (!service) return
    service.redoLast()
    root.selectedIndex = 0
    root.confirmAddress = ""
  }

  function enableProtection(extra, fromKeyboard) {
    if (!service) return
    if (fromKeyboard && !root.armed) return
    root.armed = true
    root.setupMessage = "Installing…"
    service.installBinds(JSON.stringify(extra || {}))
  }

  function laterSetup() {
    if (service && service.dismissSetup) service.dismissSetup()
    root.dismiss()
  }

  onInstallResultChanged: {
    var r = root.installResult
    if (!r || root.view !== "setup") return
    if (r.status === "ok") {
      root.setupMessage = "✓ Reprieve is active"
      if (r.conflicts && r.conflicts.length) {
        var names = []
        for (var i = 0; i < r.conflicts.length; i++) names.push(r.conflicts[i].pretty)
        root.setupMessage += " — skipped " + names.join(", ")
      }
      setupCloseTimer.restart()
    } else if (r.status === "conflict") {
      root.setupMessage = ""
    } else {
      root.setupMessage = "Setup failed: " + String(r.error || "unknown error")
    }
  }

  Timer { id: confirmTimer; interval: 3000; repeat: false; onTriggered: root.confirmAddress = "" }
  Timer { id: armTimer; interval: 2500; repeat: false; onTriggered: root.armed = true }
  Timer { id: setupCloseTimer; interval: 1600; repeat: false; onTriggered: { if (root.view === "setup") root.view = "timeline" } }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reprieve"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.view === "setup" ? Math.min(setupColumn.implicitHeight + root.contentMargin * 2, root.cardHeight) : root.cardHeight
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
            root.dismiss(); event.accepted = true; return
          }
          if (root.view === "setup") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.enableProtection({}, true); event.accepted = true }
            else if (event.key === Qt.Key_L) { root.laterSetup(); event.accepted = true }
            else if (event.key === Qt.Key_A) { root.enableProtection(alternateOptions(), true); event.accepted = true }
            else if (event.key === Qt.Key_R) { root.enableProtection(replaceOptions(), true); event.accepted = true }
            else if (event.key === Qt.Key_T && !root.needsSetup) { root.view = "timeline"; event.accepted = true }
            return
          }
          if (event.key === Qt.Key_Up || event.key === Qt.Key_K) { root.select(-1); event.accepted = true }
          else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) { root.select(1); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Z) {
            root.restoreSelected(!!(event.modifiers & Qt.ShiftModifier)); event.accepted = true
          }
          else if (event.key === Qt.Key_Space || event.key === Qt.Key_H) { root.restoreSelected(true); event.accepted = true }
          else if (event.key === Qt.Key_A) { root.restoreAll(); event.accepted = true }
          else if (event.key === Qt.Key_Y) { root.redoOnce(); event.accepted = true }
          else if (event.key === Qt.Key_Delete || event.key === Qt.Key_X) { root.closeSelected(); event.accepted = true }
          else if (event.key === Qt.Key_T) { if (service && service.toggleShowToast) service.toggleShowToast(); event.accepted = true }
          else if (event.key === Qt.Key_S) { root.view = "setup"; event.accepted = true }
        }
      }

      // ------------------------------------------------------------ setup

      Column {
        id: setupColumn
        visible: root.view === "setup"
        width: parent.width
        spacing: Style.spacing.md

        Text {
          text: "Reprieve"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.needsSetup ? "Protect Super+W from accidental closes?" : "Reprieve keybindings are installed."
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs
          Repeater {
            model: [
              ["Super+W", "Park window"],
              ["Super+Alt+W", "Close permanently"],
              ["Super+Z", "Restore"],
              ["Super+Y", "Redo"],
              ["Super+Shift+Z", "Timeline"]
            ]
            delegate: Row {
              required property var modelData
              spacing: Style.spacing.md
              Text { width: Style.space(140); text: modelData[0]; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
              Text { text: modelData[1]; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            }
          }
        }

        Column {
          visible: root.conflicts.length > 0
          width: parent.width
          spacing: Style.spacing.xs
          Repeater {
            model: root.conflicts
            delegate: Text {
              required property var modelData
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "⚠ " + modelData.pretty + " is used by \"" + String(modelData.owner || "") + "\""
                + (modelData.action === "park"
                  ? " — press R to replace it (required for Reprieve)"
                  : (modelData.alternate ? " — A uses " + prettyKey(modelData.alternate) + ", R replaces it, Enter skips it" : " — R replaces it, Enter skips it"))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(Style.space(40), Style.font.body + Style.spacing.md)
          radius: Math.max(6, Style.cornerRadius - 4)
          color: root.armed ? root.selectedBackground : root.faint
          Text {
            anchors.centerIn: parent
            text: root.setupMessage ? root.setupMessage
              : (root.needsSetup ? "Enable Protection" : "Reinstall keybindings")
            textFormat: Text.PlainText
            color: root.armed ? root.selectedText : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea { anchors.fill: parent; onClicked: root.enableProtection({}, false) }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Enter enables  ·  L later  ·  Esc close" + (root.needsSetup ? "" : "  ·  T timeline")
            + "\nNothing changes until you press Enable. Only a marked block in ~/.config/hypr/bindings.lua is written; a backup is kept."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // --------------------------------------------------------- timeline

      Column {
        visible: root.view === "timeline"
        anchors.fill: parent
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.spacing.md
          Text {
            text: "Reprieve"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.parkedCount > 0 ? (root.parkedCount + " parked") : ""
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          text: "Enter restore  ·  Space restore here  ·  A restore all  ·  Y redo  ·  Del close for good  ·  T toasts"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !!(service && service.recoveryNotice)
          width: parent.width
          wrapMode: Text.WordWrap
          text: service ? String(service.recoveryNotice || "") : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: list
          width: parent.width
          height: parent.height - Style.font.title - Style.font.caption * 3 - Style.spacing.md * 5 - Style.space(64)
          clip: true
          model: root.rows
          spacing: Style.spacing.xs
          currentIndex: root.selectedIndex
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool selected: root.cursorActive && index === root.selectedIndex
            readonly property bool confirming: modelData.address && root.confirmAddress === modelData.address
            width: list.width
            height: root.rowHeight
            radius: Math.max(6, Style.cornerRadius - 4)
            color: selected ? root.selectedBackground : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(84)
                text: modelData.kind
                color: selected ? root.selectedText : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(84) - Style.space(96) - Style.spacing.md * 2
                Text {
                  width: parent.width
                  text: modelData.label
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  visible: !!modelData.where
                  text: modelData.where
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: selected ? root.selectedText : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(96)
                height: Math.max(Style.space(26), Style.font.caption + Style.spacing.xs * 2)
                radius: Math.max(4, Style.cornerRadius - 6)
                visible: modelData.live && selected
                color: confirming ? root.foreground : root.faint
                Text {
                  anchors.centerIn: parent
                  text: confirming ? "Del: confirm" : "Del: close"
                  color: confirming ? root.background : (selected ? root.selectedText : root.muted)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: { root.selectedIndex = index; root.cursorActive = true; root.closeSelected() }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              z: -1
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
            text: root.redoCount > 0 ? "Nothing parked — Y parks the last one again" : "Nothing parked. Super+W parks a window."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          text: {
            var counts = root.rows.length === 0
              ? (root.redoCount > 0 ? (root.redoCount + " redo waiting") : "")
              : (root.rows.length + " to restore  ·  " + root.redoCount + " redo")
            var pause = service && service.pauseMediaOnPark !== false ? "  ·  audio pauses on park" : ""
            return counts + pause
          }
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Rectangle {
            width: (parent.width - Style.spacing.md) / 2
            height: Math.max(Style.space(36), Style.font.body + Style.spacing.md)
            radius: Math.max(6, Style.cornerRadius - 4)
            color: root.parkedCount > 0 ? root.selectedBackground : root.faint
            Text {
              anchors.centerIn: parent
              text: "Restore All" + (root.parkedCount > 0 ? " (" + root.parkedCount + ")" : "")
              color: root.parkedCount > 0 ? root.selectedText : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea { anchors.fill: parent; onClicked: root.restoreAll() }
          }

          Rectangle {
            width: (parent.width - Style.spacing.md) / 2
            height: Math.max(Style.space(36), Style.font.body + Style.spacing.md)
            radius: Math.max(6, Style.cornerRadius - 4)
            color: root.faint
            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(40)
                text: "Toasts"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(40)
                horizontalAlignment: Text.AlignRight
                text: service && service.showToast !== false ? "On" : "Off"
                color: service && service.showToast !== false ? root.foreground : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
            MouseArea { anchors.fill: parent; onClicked: if (service && service.toggleShowToast) service.toggleShowToast() }
          }
        }
      }
    }
  }

  function prettyKey(key) {
    return String(key || "").replace("SUPER", "Super").replace("SHIFT", "Shift").replace("CTRL", "Ctrl").replace("ALT", "Alt").replace(/ \+ /g, "+")
  }

  function alternateOptions() {
    var opts = {}
    for (var i = 0; i < root.conflicts.length; i++) {
      var c = root.conflicts[i]
      if (c.alternate && c.action !== "park") opts[c.action] = c.alternate
    }
    return opts
  }

  function replaceOptions() {
    var replace = []
    for (var i = 0; i < root.conflicts.length; i++) replace.push(root.conflicts[i].action)
    return { replace: replace }
  }

  PanelWindow {
    id: toastPanel
    visible: !!(service && service.toastOpen && service.toastText)
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "reprieve-toast"
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
