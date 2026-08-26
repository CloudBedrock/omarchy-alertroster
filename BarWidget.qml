import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bell in the bar, and the panel behind it. All state lives on the
// service; this only renders it and forwards clicks.
Panel {
  id: root
  moduleName: "alertroster.pager"
  manageIpc: false

  readonly property var pager: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("alertroster.pager") : null
  readonly property var incidents: pager ? pager.incidents : []
  readonly property bool paging: pager ? pager.paging : false
  readonly property int triggered: pager ? pager.triggeredCount : 0
  readonly property string link: pager ? pager.link : "local"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool hideWhenClear: setting("hideWhenClear", false) === true

  property int cursor: 0
  property bool cursorActive: false
  property bool openedFromHotkey: false

  // Bar widgets are the seam through which per-widget settings reach the
  // shell; the service has no entry of its own in shell.json.
  onSettingsChanged: if (pager) pager.settings = settings
  onPagerChanged: if (pager) pager.settings = settings

  visible: !(hideWhenClear && incidents.length === 0)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  function open() { openedFromHotkey = false; root.controller.show(); if (pager) pager.refresh() }
  function openFromHotkey() { openedFromHotkey = true; root.controller.show(); if (pager) pager.refresh() }
  function close() { cursorActive = false; root.controller.hide() }
  function toggle() { opened ? close() : openFromHotkey() }

  function selected() {
    if (incidents.length === 0) return null
    return incidents[Math.max(0, Math.min(cursor, incidents.length - 1))]
  }
  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    cursor = Math.max(0, Math.min(incidents.length - 1, cursor + dy))
  }
  function ackSelected() {
    var inc = selected()
    if (inc && pager && Model.canAct(inc, "acknowledged")) pager.acknowledge(inc.id)
  }
  function resolveSelected() {
    var inc = selected()
    if (inc && pager && Model.canAct(inc, "resolved")) pager.resolve(inc.id)
  }
  function linkLabel() {
    switch (link) {
      case "connected": return "Connected to AlertRoster"
      case "offline": return "AlertRoster unreachable — showing last sync"
      case "unauthorized": return "Signed out — run alertroster-login"
    }
    return "Local only — run alertroster-login to page your roster"
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barIcon(root.incidents, root.paging) + (Model.pillText(root.incidents) !== "" && !vertical ? " " + Model.pillText(root.incidents) : "")
    slotSize: Style.bar.iconSlot * (Model.pillText(root.incidents) !== "" && !vertical ? 1.6 : 1)
    activeColor: root.urgent
    useActiveColor: true
    active: root.triggered > 0
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.pager) root.pager.refresh() }
      else root.toggle()
    }

    SequentialAnimation on opacity {
      running: root.paging
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.35; duration: 500 }
      NumberAnimation { from: 0.35; to: 1.0; duration: 500 }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.ackSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a") root.ackSelected()
        else if (t === "r") root.resolveSelected()
        else if (t === "R" && root.pager) root.pager.refresh()
        else if (t === "t" && root.pager) root.pager.page("Test page from the panel", "high", "test")
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: root.paging ? "Paging" : (root.incidents.length > 0 ? root.incidents.length + " open" : "All quiet")
          meta: root.linkLabel().toUpperCase()
          iconComponent: Component {
            Text {
              text: Model.barIcon(root.incidents, root.paging)
              color: root.triggered > 0 ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          visible: root.incidents.length > 0
          text: "Open incidents"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.incidents.length === 0
          width: parent.width
          text: "Nothing is paging you.\n\nTry:  alertroster-page \"Deploy failed\"\nor press  t  for a test page."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        Repeater {
          model: root.incidents
          delegate: CursorSurface {
            id: row
            required property var modelData
            required property int index
            width: column.width
            implicitHeight: rowContent.implicitHeight + Style.spacing.controlPaddingY * 2
            hasCursor: root.cursorActive && root.cursor === index
            foreground: root.foreground
            accent: Color.accent

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: { root.cursorActive = true; root.cursor = row.index }
              onClicked: root.ackSelected()
            }

            Row {
              id: rowContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              spacing: Style.space(10)

              Rectangle {
                width: Style.space(4)
                height: rowLabels.implicitHeight
                radius: 2
                color: row.modelData.status === "triggered" ? root.urgent : root.dim
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: rowLabels
                width: parent.width - Style.space(4) - Style.space(10) * 2 - actions.width
                spacing: Style.space(2)
                Text {
                  width: parent.width
                  text: row.modelData.title
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.modelData.status === "triggered"
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: Model.statusLabel(row.modelData) + " · " + Model.sourceLabel(row.modelData) + " · " + Model.ageLabel(row.modelData.triggered_at, root.pager ? root.pager.nowMs : Date.now()) + (row.modelData.escalate_at ? " · " + Model.countdownLabel(row.modelData.escalate_at, root.pager ? root.pager.nowMs : Date.now()) : "")
                  textFormat: Text.PlainText
                  color: row.modelData.emergency ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Row {
                id: actions
                spacing: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                PanelActionButton {
                  visible: Model.canAct(row.modelData, "acknowledged")
                  iconText: "󰄬"
                  tooltipText: "Acknowledge (a)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.pager) root.pager.acknowledge(row.modelData.id)
                }
                PanelActionButton {
                  visible: Model.canAct(row.modelData, "resolved")
                  iconText: "󰸞"
                  tooltipText: "Resolve (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.pager) root.pager.resolve(row.modelData.id)
                }
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        Text {
          width: parent.width
          text: (root.pager && root.pager.lastError !== "" ? root.pager.lastError + "\n" : "")
            + "a acknowledge · r resolve · R refresh · t test page · Esc close"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
