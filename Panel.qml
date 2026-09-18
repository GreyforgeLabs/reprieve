import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ReprieveModel.js" as Model
import "BarIcons.js" as Icons
import "brand"

// Reprieve overlay: the recovery timeline, the first-run setup card, and the
// small top-right toast. Colours and fonts come from the Omarchy theme; the
// Greyforge mark, cyan seams and amber core are fixed brand colours.
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
  // Ticking clock for per-row timeout countdowns, refreshed by
  // countdownTimer while the timeline is open with an active timeout.
  property double nowTick: 0
  // An auto-opened setup card grabs keyboard focus while the user may still
  // be typing. Keyboard consent is disarmed for a moment so a stray Enter
  // cannot install anything; a mouse click is always deliberate.
  property bool armed: false

  readonly property real prefHeight: Math.round(buttonHeight * 1.55)
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  // Greyforge Labs brand colours (fixed, theme-independent).
  readonly property color brandAmber: "#fda52b"
  readonly property color brandCyan: "#38c8e8"
  readonly property color amberInk: "#1a1206"
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(600), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(Style.space(52), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int buttonHeight: Math.max(Style.space(38), Style.font.body + Style.spacing.md * 2)
  readonly property int cardRadius: Math.max(Style.space(10), cornerRadius)
  readonly property int innerRadius: Math.max(Style.space(6), cornerRadius - 4)

  function iconFor(klass) { return Icons.resolve(klass, Quickshell, DesktopEntries) }
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
        klass: action.class || "",
        kind: kind,
        index: i,
        address: action.address || "",
        live: action.type === "park",
        parkedAt: action.type === "park" ? Number(action.parkedAt || 0) : 0,
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
    root.nowTick = Date.now()
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

  // Per-row timeout countdown. Empty string means no deadline: timeout
  // off, unstamped pre-timeout history, or a non-park row. Read inside the
  // delegate (not baked into `rows`) so the 1 s tick updates text in place
  // instead of rebuilding the list and resetting its scroll position.
  function countdownSuffix(live, parkedAt) {
    var timeout = root.service ? Number(root.service.parkTimeout || 0) : 0
    var stamp = Number(parkedAt || 0)
    if (!(timeout > 0 && live && stamp > 0)) return ""
    var now = root.nowTick > 0 ? root.nowTick : Date.now()
    var s = Math.max(0, Math.ceil((stamp + timeout * 1000 - now) / 1000))
    return "closes in " + s + "s"
  }

  // Preferences reachable from the timeline. Auto-close steps through a
  // few sensible presets rather than a free-form number; the CLI still
  // accepts any value in 5–120 s.
  readonly property var timeoutPresets: [0, 15, 30, 60, 120]
  readonly property int parkTimeoutValue: service ? Number(service.parkTimeout || 0) : 0

  function timeoutLabel(seconds) {
    var n = Number(seconds || 0)
    if (n <= 0) return "Off"
    return n >= 60 && n % 60 === 0 ? (n / 60) + " min" : n + " s"
  }

  // Flight steps off -> subtle -> angel (Shift+F back).
  readonly property string flightValue: service ? Model.normalizeFlight(service.flight) : Model.DEFAULT_FLIGHT
  function cycleFlight(direction) {
    if (!service || typeof service.setSetting !== "function") return
    var modes = Model.FLIGHT_MODES
    var idx = modes.indexOf(root.flightValue)
    var next = modes[((idx === -1 ? 0 : idx) + (direction < 0 ? -1 : 1) + modes.length) % modes.length]
    service.setSetting("flight", next)
  }

  function cycleParkTimeout(direction) {
    if (!service || typeof service.setSetting !== "function") return
    var cur = root.parkTimeoutValue
    var idx = -1
    for (var i = 0; i < root.timeoutPresets.length; i++) if (root.timeoutPresets[i] === cur) { idx = i; break }
    var next
    if (idx === -1) {
      // A CLI value off the preset list: step to the nearest preset in the
      // requested direction.
      next = direction > 0 ? 0 : root.timeoutPresets[root.timeoutPresets.length - 1]
      for (var j = 0; j < root.timeoutPresets.length; j++) {
        var p = root.timeoutPresets[j]
        if (direction > 0 && p > cur) { next = p; break }
        if (direction < 0 && p < cur) next = p
      }
    } else {
      next = root.timeoutPresets[(idx + direction + root.timeoutPresets.length) % root.timeoutPresets.length]
    }
    service.setSetting("parkTimeout", String(next))
    root.nowTick = Date.now()
  }

  function togglePauseMedia() {
    if (!service || typeof service.setSetting !== "function") return
    service.setSetting("pauseMediaOnPark", service.pauseMediaOnPark !== false ? "off" : "on")
  }

  function currentRow() {
    if (root.rows.length === 0) return null
    return root.rows[Math.min(root.selectedIndex, root.rows.length - 1)] || null
  }

  function restoreSelected(here) {
    if (!service) return
    var row = root.currentRow()
    if (!row) return
    // Rows snapshot their model index at render time, but the timeout sweep
    // can remove entries between render and click. Resolve by address (the
    // service finds the live index) and use the snapshot index only for
    // address-less Reopen rows.
    if (row.address) service.restoreAddress(row.address, here === true)
    else service.restoreAt(row.index, here === true)
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
  // Refresh the per-row timeout countdowns once a second. Runs only while
  // the timeline is open with an active timeout and rows to show.
  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    running: root.opened && root.view === "timeline" && root.rows.length > 0
      && (root.service ? Number(root.service.parkTimeout || 0) > 0 : false)
    onTriggered: root.nowTick = Date.now()
  }

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

    // Soft drop shadow: a darker plate offset behind the card.
    Rectangle {
      anchors.fill: card
      anchors.margins: -Style.space(2)
      anchors.topMargin: Style.space(2)
      radius: root.cardRadius + Style.space(2)
      color: Qt.rgba(0, 0, 0, 0.35)
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.view === "setup" ? Math.min(setupColumn.implicitHeight + root.contentMargin * 2, root.cardHeight) : root.cardHeight
      radius: root.cardRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Blueprint construction circles: the Greyforge plate motif, faint.
      Canvas {
        anchors.fill: parent
        opacity: 0.55
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var cx = width * 0.12, cy = height * 0.18
          ctx.lineWidth = 1
          ctx.strokeStyle = Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.10)
          ctx.beginPath(); ctx.arc(cx, cy, height * 0.42, 0, Math.PI * 2); ctx.stroke()
          ctx.setLineDash([3, 9])
          ctx.strokeStyle = Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.14)
          ctx.beginPath(); ctx.arc(cx, cy, height * 0.32, 0, Math.PI * 2); ctx.stroke()
          ctx.setLineDash([])
          ctx.strokeStyle = Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.05)
          for (var x = 0; x < width; x += 40) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke() }
          for (var y = 0; y < height; y += 40) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke() }
        }
      }

      // Top accent rail: steel gradient with the amber core at the left.
      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(3)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: root.brandAmber }
          GradientStop { position: 0.12; color: root.brandCyan }
          GradientStop { position: 0.6; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.margins: root.contentMargin

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
          else if (event.key === Qt.Key_M) { root.togglePauseMedia(); event.accepted = true }
          else if (event.key === Qt.Key_P) { root.cycleParkTimeout(event.modifiers & Qt.ShiftModifier ? -1 : 1); event.accepted = true }
          else if (event.key === Qt.Key_F) { root.cycleFlight(event.modifiers & Qt.ShiftModifier ? -1 : 1); event.accepted = true }
          else if (event.key === Qt.Key_S) { root.view = "setup"; event.accepted = true }
        }
      }

      // Shared hero: mark, product name, Greyforge Labs byline, status.
      component Hero: Item {
        id: hero
        property string meta: ""
        property string status: ""
        property bool alert: false
        width: parent.width
        implicitHeight: Math.max(heroMark.height, heroLabels.implicitHeight)
        height: implicitHeight

        ReprieveAngel {
          id: heroMark
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          size: Style.space(44)
          surface: root.background
          dot: Color.urgent
          showDot: hero.alert
        }

        Column {
          id: heroLabels
          anchors.left: heroMark.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            spacing: Style.space(10)
            Text {
              id: heroTitle
              text: "Reprieve"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              font.letterSpacing: 0.5
            }
            Rectangle {
              visible: hero.status !== ""
              anchors.verticalCenter: heroTitle.verticalCenter
              width: statusText.implicitWidth + Style.space(12)
              height: statusText.implicitHeight + Style.space(4)
              radius: height / 2
              color: hero.alert ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.18) : Qt.rgba(root.brandAmber.r, root.brandAmber.g, root.brandAmber.b, 0.16)
              border.width: 1
              border.color: hero.alert ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.6) : Qt.rgba(root.brandAmber.r, root.brandAmber.g, root.brandAmber.b, 0.55)
              Text {
                id: statusText
                anchors.centerIn: parent
                text: hero.status
                textFormat: Text.PlainText
                color: hero.alert ? Color.urgent : root.brandAmber
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Text {
            width: parent.width
            text: ("GREYFORGE LABS" + (hero.meta ? "  ·  " + hero.meta : "")).toUpperCase()
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.brandCyan
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.6
          }
        }
      }

      // A primary/secondary action button in the panel.
      component ActionButton: Rectangle {
        id: btn
        property string label: ""
        property string hint: ""
        property bool primary: false
        property bool enabledState: true
        signal clicked()
        height: root.buttonHeight
        radius: root.innerRadius
        color: primary && enabledState
          ? (btnMouse.containsMouse ? Qt.lighter(root.brandAmber, 1.08) : root.brandAmber)
          : (btnMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : root.faint)
        border.width: 1
        border.color: primary && enabledState ? Qt.rgba(1, 1, 1, 0.18) : root.hairline
        opacity: enabledState ? 1 : 0.55
        Behavior on color { ColorAnimation { duration: 120 } }
        Row {
          anchors.centerIn: parent
          spacing: Style.space(8)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: btn.label
            textFormat: Text.PlainText
            color: btn.primary && btn.enabledState ? root.amberInk : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: btn.primary
          }
          Keycap {
            visible: btn.hint !== ""
            anchors.verticalCenter: parent.verticalCenter
            key: btn.hint
            foreground: btn.primary && btn.enabledState ? root.amberInk : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
          }
        }
        MouseArea {
          id: btnMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: btn.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (btn.enabledState) btn.clicked()
        }
      }

      // A labelled on/off switch in the preferences strip.
      component PrefSwitch: Rectangle {
        id: sw
        property string label: ""
        property string description: ""
        property string hint: ""
        property bool on: false
        signal toggled()
        height: root.prefHeight
        radius: root.innerRadius
        color: swMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : root.faint
        border.width: 1
        border.color: root.hairline
        Behavior on color { ColorAnimation { duration: 100 } }
        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.md
          anchors.rightMargin: Style.spacing.md
          spacing: Style.space(6)
          PrefLabel {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - track.width - hintCap.width - parent.spacing * 2
            label: sw.label
            description: sw.description
          }
          Keycap {
            id: hintCap
            anchors.verticalCenter: parent.verticalCenter
            visible: sw.hint !== ""
            key: sw.hint
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
          }
          Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(32)
            height: Style.space(18)
            radius: height / 2
            color: sw.on ? Qt.rgba(root.brandAmber.r, root.brandAmber.g, root.brandAmber.b, 0.35) : root.faint
            border.width: 1
            border.color: sw.on ? root.brandAmber : root.hairline
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
              width: parent.height - 4
              height: width
              radius: width / 2
              y: 2
              x: sw.on ? parent.width - width - 2 : 2
              color: sw.on ? root.brandAmber : root.muted
              Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
          }
        }
        MouseArea {
          id: swMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: sw.toggled()
        }
      }

      // Name plus a one-line explanation, used by every preference card.
      component PrefLabel: Column {
        property string label: ""
        property string description: ""
        spacing: Style.space(1)
        Text {
          width: parent.width
          text: parent.label
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          width: parent.width
          visible: parent.description !== ""
          text: parent.description
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // A labelled value that steps through presets: click / wheel-up / P
      // for the next one, right-click / wheel-down / Shift+P for the previous.
      component PrefStepper: Rectangle {
        id: st
        property string label: ""
        property string description: ""
        property string hint: ""
        property string value: ""
        property bool active: false
        signal stepped(int direction)
        height: root.prefHeight
        radius: root.innerRadius
        color: stMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : root.faint
        border.width: 1
        border.color: st.active ? Qt.rgba(root.brandAmber.r, root.brandAmber.g, root.brandAmber.b, 0.5) : root.hairline
        Behavior on color { ColorAnimation { duration: 100 } }
        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.md
          anchors.rightMargin: Style.spacing.md
          spacing: Style.space(6)
          PrefLabel {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - valuePill.width - stHint.width - parent.spacing * 2
            label: st.label
            description: st.description
          }
          Keycap {
            id: stHint
            anchors.verticalCenter: parent.verticalCenter
            visible: st.hint !== ""
            key: st.hint
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
          }
          Rectangle {
            id: valuePill
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(Style.space(40), valueText.implicitWidth + Style.space(14))
            height: Style.space(18)
            radius: height / 2
            color: st.active ? Qt.rgba(root.brandAmber.r, root.brandAmber.g, root.brandAmber.b, 0.35) : root.faint
            border.width: 1
            border.color: st.active ? root.brandAmber : root.hairline
            Text {
              id: valueText
              anchors.centerIn: parent
              text: st.value + " ▸"
              textFormat: Text.PlainText
              color: st.active ? root.brandAmber : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: st.active
            }
          }
        }
        MouseArea {
          id: stMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function(mouse) { st.stepped(mouse.button === Qt.RightButton ? -1 : 1) }
          onWheel: function(wheel) { if (wheel.angleDelta.y !== 0) st.stepped(wheel.angleDelta.y > 0 ? 1 : -1) }
        }
      }

      // ------------------------------------------------------------ setup

      Column {
        id: setupColumn
        visible: root.view === "setup"
        width: parent.width
        spacing: Style.spacing.lg

        Hero {
          meta: "Setup"
          status: root.needsSetup ? "NOT PROTECTED" : "ACTIVE"
          alert: root.needsSetup
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.needsSetup ? "Protect Super+W from accidental closes?" : "Reprieve keybindings are installed."
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "The window is parked on a hidden workspace instead of being killed. Tabs, scrollback and unsaved work stay exactly as they were."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // Keybinding table
        Rectangle {
          width: parent.width
          height: bindColumn.implicitHeight + Style.space(16)
          radius: root.innerRadius
          color: root.faint
          border.width: 1
          border.color: root.hairline
          Column {
            id: bindColumn
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(4)
            Repeater {
              model: [
                ["Super", "W", "Park the focused window", true],
                ["Super", "Z", "Restore the last parked window", false],
                ["Super", "Y", "Park it again (redo)", false],
                ["Super+Shift", "Z", "Open this timeline", false],
                ["Super+Alt", "W", "Close permanently", false]
              ]
              delegate: Item {
                required property var modelData
                width: parent.width
                height: Math.max(Style.space(26), Style.font.body + Style.space(10))
                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  Keycap { key: modelData[0]; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption; emphasis: modelData[3] }
                  Text { anchors.verticalCenter: parent.verticalCenter; text: "+"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Keycap { key: modelData[1]; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption; emphasis: modelData[3] }
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData[2]
                  textFormat: Text.PlainText
                  color: modelData[3] ? root.foreground : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }

        Column {
          visible: root.conflicts.length > 0
          width: parent.width
          spacing: Style.spacing.xs
          Repeater {
            model: root.conflicts
            delegate: Rectangle {
              required property var modelData
              width: parent.width
              height: conflictText.implicitHeight + Style.space(12)
              radius: root.innerRadius
              color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.10)
              border.width: 1
              border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)
              Text {
                id: conflictText
                anchors.fill: parent
                anchors.margins: Style.space(6)
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
        }

        ActionButton {
          width: parent.width
          primary: root.armed
          label: root.setupMessage ? root.setupMessage
            : (root.needsSetup ? "Enable Protection" : "Reinstall keybindings")
          hint: root.setupMessage ? "" : "Enter"
          onClicked: root.enableProtection({}, false)
        }

        Flow {
          width: parent.width
          spacing: Style.space(12)
          Keycap { key: "L"; label: "later"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { key: "Esc"; label: "close"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { visible: !root.needsSetup; key: "T"; label: "timeline"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Nothing changes until you press Enable. Only a marked block in ~/.config/hypr/bindings.lua is written; a backup is kept."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        GreyforgeWordmark {
          foreground: root.foreground
          plate: root.background
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
        }
      }

      // --------------------------------------------------------- timeline

      Column {
        id: timelineColumn
        visible: root.view === "timeline"
        anchors.fill: parent
        spacing: Style.spacing.lg

        Hero {
          id: timelineHero
          meta: "Recovery timeline" + (root.redoCount > 0 ? " · " + root.redoCount + " redo" : "")
          status: service && service.recoveryNotice ? "RECOVERED" : (root.parkedCount > 0 ? String(root.parkedCount) + " PARKED" : "")
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        Rectangle {
          visible: !!(service && service.recoveryNotice)
          width: parent.width
          height: visible ? noticeText.implicitHeight + Style.space(12) : 0
          radius: root.innerRadius
          color: Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.08)
          border.width: 1
          border.color: Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.35)
          Text {
            id: noticeText
            anchors.fill: parent
            anchors.margins: Style.space(6)
            wrapMode: Text.WordWrap
            text: service ? String(service.recoveryNotice || "") : ""
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        ListView {
          id: list
          width: parent.width
          height: parent.height - timelineHero.height - hintRow.height - footerRow.height - signature.height - 1 - Style.spacing.lg * 5
          clip: true
          model: root.rows
          spacing: Style.spacing.xs
          currentIndex: root.selectedIndex
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: rowItem
            required property var modelData
            required property int index
            readonly property bool selected: root.cursorActive && index === root.selectedIndex
            readonly property bool confirming: modelData.address && root.confirmAddress === modelData.address
            readonly property bool hot: selected || rowMouse.containsMouse
            readonly property string iconSource: root.iconFor(modelData.klass)
            readonly property string countdown: root.countdownSuffix(modelData.live, modelData.parkedAt)
            width: list.width
            height: root.rowHeight
            radius: root.innerRadius
            color: selected ? root.selectedBackground : (rowMouse.containsMouse ? root.faint : "transparent")
            border.width: 1
            border.color: selected ? Qt.rgba(root.brandCyan.r, root.brandCyan.g, root.brandCyan.b, 0.45) : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }

            // selection rail
            Rectangle {
              visible: rowItem.selected
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(6)
              width: Style.space(3)
              radius: width
              color: root.brandCyan
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.spacing.md
              spacing: Style.spacing.md

              // App icon in a small steel plate
              Rectangle {
                id: iconPlate
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(34)
                height: width
                radius: root.innerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                border.width: 1
                border.color: root.hairline
                opacity: modelData.live ? 1 : 0.5
                Image {
                  anchors.centerIn: parent
                  visible: rowItem.iconSource !== ""
                  source: rowItem.iconSource
                  width: Style.space(22)
                  height: width
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  asynchronous: true
                }
                Text {
                  anchors.centerIn: parent
                  visible: rowItem.iconSource === ""
                  text: modelData.live ? "󰖯" : "󰑐"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - iconPlate.width - kindChip.width - Style.space(96) - Style.spacing.md * 3
                spacing: Style.space(2)
                Text {
                  width: parent.width
                  text: modelData.label
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: rowItem.selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: rowItem.selected
                }
                Row {
                  spacing: Style.space(8)
                  Text {
                    visible: !!modelData.where
                    text: modelData.where
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    visible: rowItem.countdown !== ""
                    text: "󱎫 " + rowItem.countdown
                    textFormat: Text.PlainText
                    color: root.brandAmber
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              // Kind chip: Parked / Recovered / Reopen
              Rectangle {
                id: kindChip
                anchors.verticalCenter: parent.verticalCenter
                width: kindText.implicitWidth + Style.space(12)
                height: kindText.implicitHeight + Style.space(6)
                radius: height / 2
                readonly property color tone: modelData.kind === "Parked" ? root.brandCyan : (modelData.kind === "Recovered" ? root.brandAmber : root.muted)
                color: Qt.rgba(tone.r, tone.g, tone.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.45)
                Text {
                  id: kindText
                  anchors.centerIn: parent
                  text: modelData.kind.toUpperCase()
                  textFormat: Text.PlainText
                  color: kindChip.tone
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.8
                }
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(96)
                height: Math.max(Style.space(26), Style.font.caption + Style.spacing.xs * 2)
                radius: root.innerRadius
                visible: modelData.live && rowItem.hot
                color: rowItem.confirming ? Color.urgent : root.faint
                border.width: 1
                border.color: rowItem.confirming ? Color.urgent : root.hairline
                Text {
                  anchors.centerIn: parent
                  text: rowItem.confirming ? "Sure? Del" : "Del · close"
                  color: rowItem.confirming ? root.background : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: rowItem.confirming
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: { root.selectedIndex = index; root.cursorActive = true; root.closeSelected() }
                }
              }
            }

            MouseArea {
              id: rowMouse
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

          // Empty state
          Column {
            visible: root.rows.length === 0
            anchors.centerIn: parent
            width: parent.width
            spacing: Style.space(10)
            ReprieveAngel {
              anchors.horizontalCenter: parent.horizontalCenter
              size: Style.space(72)
              surface: root.background
              artOpacity: 0.55
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.redoCount > 0 ? "Nothing parked" : "Nothing parked"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.redoCount > 0 ? "Y parks the last window again." : "Super+W parks a window instead of killing it."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Flow {
          id: hintRow
          width: parent.width
          spacing: Style.space(12)
          Keycap { key: "Enter"; label: "restore"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { key: "Space"; label: "restore here"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { key: "A"; label: "restore all"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { key: "Y"; label: "redo"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
          Keycap { key: "Del"; label: "close for good"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }
        }

        // Preferences strip: every toggle the service honours, flipped from
        // the timeline. Writes go through the service so shell.json and the
        // CLI (`reprieve set …`) stay the single source of truth.
        Column {
          id: footerRow
          width: parent.width
          spacing: Style.spacing.md

          ActionButton {
            width: parent.width
            primary: true
            enabledState: root.parkedCount > 0
            label: "Restore All" + (root.parkedCount > 0 ? " (" + root.parkedCount + ")" : "")
            hint: "A"
            onClicked: root.restoreAll()
          }

          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.sm
            readonly property real cell: (width - Style.spacing.md) / 2

            PrefSwitch {
              width: parent.cell
              label: "Toasts"
              description: "Corner notice on park and return"
              hint: "T"
              on: service && service.showToast !== false
              onToggled: if (service && service.toggleShowToast) service.toggleShowToast()
            }

            PrefSwitch {
              width: parent.cell
              label: "Pause audio"
              description: "Pause media players while parked"
              hint: "M"
              on: service && service.pauseMediaOnPark !== false
              onToggled: root.togglePauseMedia()
            }

            PrefStepper {
              width: parent.cell
              label: "Auto-close"
              description: "Close parked windows on a timer"
              hint: "P"
              value: root.timeoutLabel(root.parkTimeoutValue)
              active: root.parkTimeoutValue > 0
              onStepped: function(direction) { root.cycleParkTimeout(direction) }
            }

            PrefStepper {
              width: parent.cell
              label: "Flight"
              description: root.flightValue === "angel" ? "A winged light carries the window" : (root.flightValue === "subtle" ? "The window glides into the bar" : "Park and restore are a plain cut")
              hint: "F"
              value: root.flightValue
              active: root.flightValue !== "off"
              onStepped: function(direction) { root.cycleFlight(direction) }
            }
          }
        }

        Item {
          id: signature
          width: parent.width
          height: wordmark.height
          GreyforgeWordmark {
            id: wordmark
            anchors.left: parent.left
            foreground: root.foreground
            plate: root.background
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Super+Shift+Z"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
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

  // Park/restore flights (their own overlay layers, mapped only in flight).
  Flight { service: root.service }

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
      id: toastCard
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(44)
      anchors.rightMargin: Style.space(16)
      width: toastRow.implicitWidth + Style.spacing.md * 2 + Style.space(6)
      height: Math.max(toastRow.implicitHeight, Style.space(24)) + Style.spacing.md * 2
      radius: root.innerRadius
      color: root.background
      border.width: Math.max(1, Style.space(1))
      border.color: root.border
      clip: true

      // amber edge rail
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(3)
        color: root.brandAmber
      }

      Row {
        id: toastRow
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: Style.space(3)
        spacing: Style.space(8)
        ReprieveAngel {
          anchors.verticalCenter: parent.verticalCenter
          size: Style.space(20)
          surface: root.background
        }
        Text {
          id: toastLabel
          anchors.verticalCenter: parent.verticalCenter
          text: service ? (service.toastText || "") : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
