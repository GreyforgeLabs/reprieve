import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "ReprieveModel.js" as Model
import "BarIcons.js" as Icons

// Reprieve bar widget: the place a parked window visibly went.
//
//   glyph [count]   — always; amber when something needs attention
//   app icons       — one per parked window, newest first (barTray)
//
// Stateless: everything comes from the live service. Under a replacement bar
// (service-less facade) it degrades to a glyph that opens the timeline.
BarWidget {
  id: root
  moduleName: "tech.greyforge.reprieve"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var parkedEntries: {
    var undo = service && service.undoStack ? service.undoStack : []
    var out = []
    for (var i = undo.length - 1; i >= 0; i--) {
      var a = undo[i]
      if (a && a.type === "park" && a.address) out.push(a)
    }
    return out
  }
  readonly property int parked: parkedEntries.length
  readonly property bool attention: !!(service && service.attention)
  readonly property string attentionReason: service ? String(service.attentionReason || "") : ""
  readonly property bool tray: setting("tray", service ? service.barTray : true) !== false
  readonly property int maxIcons: Math.max(1, Math.min(10, Math.floor(Number(setting("maxIcons", service ? service.barMaxIcons : 5)) || 5)))
  readonly property bool hideWhenIdle: setting("hideWhenIdle", service ? service.hideBarWhenIdle : true) !== false
  readonly property bool showInBar: setting("showInBar", service ? service.showInBar : true) !== false
  readonly property var trayEntries: tray ? parkedEntries.slice(0, maxIcons) : []
  readonly property int overflow: tray ? Math.max(0, parked - maxIcons) : parked
  readonly property string glyph: ""
  readonly property real iconSize: Style.bar.iconCanvas
  property bool pulse: false

  visible: showInBar && (service ? (parked > 0 || attention || !hideWhenIdle) : !hideWhenIdle)
  implicitWidth: vertical ? barSize : layout.implicitWidth
  implicitHeight: vertical ? layout.implicitHeight : barSize

  function newestLabel() {
    return parkedEntries.length ? Model.sanitizeLabel(parkedEntries[0].label || parkedEntries[0].class, 40) : ""
  }

  function summaryTooltip() {
    if (attention) return attentionReason
    if (!service) return "Reprieve — click for the timeline"
    if (parked === 0) return "Reprieve — nothing parked. Super+W parks a window."
    var text = parked + " parked · newest: " + newestLabel()
    return text + "\nclick: timeline · right: restore last · middle: restore all"
  }

  function openTimeline() {
    if (service && service.openTimeline) { service.openTimeline(); return }
    if (bar) bar.run("omarchy-shell shell toggle " + moduleName + " '{\"view\":\"timeline\"}'")
  }

  function onSummaryPressed(button) {
    if (attention && service && !service.bindsInstalled) { service.openSetup(); return }
    if (attention && service && service.legacyDetected) { service.openSetup(); return }
    if (button === Qt.RightButton && service) { service.undoLast(); return }
    if (button === Qt.MiddleButton && service) { service.restoreAll(); return }
    root.openTimeline()
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onWindowParked() { root.pulse = true; pulseTimer.restart() }
  }
  Timer { id: pulseTimer; interval: 1200; repeat: false; onTriggered: root.pulse = false }

  Flow {
    id: layout
    anchors.centerIn: parent
    flow: root.vertical ? Flow.TopToBottom : Flow.LeftToRight
    spacing: 0

    WidgetButton {
      id: summary
      bar: root.bar
      text: root.vertical || root.overflow === 0 ? root.glyph : (root.glyph + " " + (root.tray ? "+" : "") + root.overflow)
      fontSize: Style.font.caption
      active: root.attention || root.pulse
      tooltipText: root.summaryTooltip()
      onPressed: function(button) { root.onSummaryPressed(button) }
    }

    Repeater {
      model: root.trayEntries
      delegate: WidgetButton {
        id: slot
        required property var modelData
        readonly property string iconSource: Icons.resolve(modelData.class, Quickshell, DesktopEntries)
        bar: root.bar
        text: iconSource ? "" : ""
        hasVisualContent: true
        fontSize: Style.font.caption
        fixedWidth: root.vertical ? -1 : Style.bar.statusSlot + 6
        fixedHeight: root.vertical ? Style.bar.statusSlot + 6 : -1
        tooltipText: Model.sanitizeLabel(modelData.label || modelData.class, 48)
          + (modelData.workspace ? " · workspace " + modelData.workspace : "")
          + (modelData.recovered ? " · recovered" : "")
          + "\nclick: restore · right: restore here"
        onPressed: function(button) {
          if (!root.service) return
          if (button === Qt.RightButton) root.service.restoreAddress(modelData.address, true)
          else if (button === Qt.MiddleButton) root.openTimeline()
          else root.service.restoreAddress(modelData.address, false)
        }

        IconImage {
          visible: slot.iconSource !== ""
          anchors.centerIn: parent
          implicitSize: root.iconSize
          source: slot.iconSource
          opacity: modelData.recovered ? 0.7 : 1
        }
      }
    }
  }
}
