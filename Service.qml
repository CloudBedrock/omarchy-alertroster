import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// The pager. One instance for the whole shell; holds the open incident set,
// raises the takeover, loops the alarm, and answers IPC.
//
// It is a thin client on purpose. For incidents from AlertRoster it renders
// what the core sent — `emergency`, `available_actions`, `status` — and never
// decides any of them itself. For pages raised on this machine there is no
// core, so Model.js applies the single rule the core applies today (high +
// triggered = paging until acknowledged) and nothing more: no escalation, no
// roster, no phones. That gap is what signing in is for.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  // Pushed in by the bar widget from its shell.json entry.
  property var settings: ({})

  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string binDir: pluginDir + "/bin"
  readonly property string alarmFile: pluginDir + "/sounds/alarm.wav"

  // ---------------------------------------------------------------- state
  property var localIncidents: []
  property var remoteIncidents: []
  property int localSerial: 0

  // "local" — not signed in; "connected"; "offline" — signed in but the core
  // is unreachable; "unauthorized" — tokens dead, sign in again.
  property string link: "local"
  property string lastError: ""
  property double lastSyncMs: 0
  property bool syncing: false
  property double nowMs: Date.now()

  readonly property var incidents: Model.sortForBoard(Model.openOnly(localIncidents).concat(Model.openOnly(remoteIncidents)))
  readonly property var emergencyIncident: Model.firstEmergency(incidents)
  readonly property bool paging: emergencyIncident !== null
  readonly property int triggeredCount: Model.countTriggered(incidents)

  readonly property bool soundEnabled: setting("sound", true) === true
  readonly property bool takeoverEnabled: setting("takeover", true) === true
  readonly property int refreshIntervalSec: Math.max(2, Math.min(300, parseInt(String(setting("refreshIntervalSec", 5)), 10) || 5))

  // Set while an ack/resolve is in flight for the takeover's incident, so the
  // surface can say so — nothing else is visible while it is up.
  property string pendingAction: ""
  property string actionError: ""

  signal incidentOpened(var incident)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function nowIso() { return new Date().toISOString() }

  // ---------------------------------------------------------------- pages
  function page(title, urgency, source) {
    localSerial += 1
    var incident = Model.makeLocalIncident(localSerial, title, urgency, source, nowIso())
    localIncidents = localIncidents.concat([incident])
    announce(incident)
    return incident.id
  }

  function announce(incident) {
    incidentOpened(incident)
    if (incident.emergency && takeoverEnabled) return // the takeover *is* the notification
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      "--app-name", "AlertRoster",
      "-g", "󰂞",
      "-u", incident.urgency === "high" ? "critical" : "normal",
      incident.title,
      Model.sourceLabel(incident) + " · " + Model.statusLabel(incident).toLowerCase()
    ])
  }

  function findIncident(id) {
    var all = localIncidents.concat(remoteIncidents)
    for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i]
    return null
  }

  function act(id, action) {
    var incident = findIncident(id)
    if (!incident) return "unknown"
    if (!Model.canAct(incident, action)) return "refused"
    if (Model.isLocal(incident)) {
      var next = []
      for (var i = 0; i < localIncidents.length; i++)
        next.push(localIncidents[i].id === id ? Model.applyLocalTransition(localIncidents[i], action, nowIso()) : localIncidents[i])
      localIncidents = next
      return "ok"
    }
    // Remote: ask the core, then re-sync. The takeover comes down when the
    // core stops flagging the incident, not because a button was pressed.
    if (actionProcess.running) return "busy"
    pendingAction = action
    actionError = ""
    actionProcess.incidentId = id
    var route = action === "acknowledged" ? "acknowledge" : "resolve"
    actionProcess.command = [binDir + "/alertroster-api", "POST", "/api/v1/incidents/" + id + "/" + route]
    actionProcess.running = true
    return "sent"
  }

  function acknowledge(id) { return act(id, "acknowledged") }
  function resolve(id) { return act(id, "resolved") }

  function acknowledgeEmergency() {
    if (emergencyIncident) acknowledge(emergencyIncident.id)
  }

  function clearLocal() {
    localIncidents = []
  }

  // ---------------------------------------------------------------- sync
  function refresh() {
    if (syncProcess.running) return
    syncing = true
    syncProcess.command = [binDir + "/alertroster-api", "GET", "/api/v1/incidents"]
    syncProcess.running = true
  }

  function applyRemote(list) {
    // Announce what is new to this machine. Deltas the core made to incidents
    // we already knew about (ack, escalation) arrive as ordinary replacements.
    var known = {}
    for (var i = 0; i < remoteIncidents.length; i++) known[remoteIncidents[i].id] = true
    var fresh = []
    for (var j = 0; j < list.length; j++) if (!known[list[j].id] && lastSyncMs > 0) fresh.push(list[j])
    remoteIncidents = list
    lastSyncMs = Date.now()
    for (var k = 0; k < fresh.length; k++) announce(fresh[k])
  }

  Process {
    id: syncProcess
    running: false
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    stderr: StdioCollector { id: syncErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.syncing = false
      if (exitCode === 0) {
        var list = Model.parseIncidentList(syncOut.text)
        if (list === null) { root.lastError = "unreadable reply"; root.link = "offline"; return }
        root.link = "connected"
        root.lastError = ""
        root.applyRemote(list)
      } else if (exitCode === 3) {
        root.link = "local"
        root.remoteIncidents = []
      } else if (exitCode === 4) {
        root.link = "unauthorized"
        root.lastError = "Signed out — run alertroster-login"
      } else {
        root.link = root.link === "local" ? "local" : "offline"
        root.lastError = String(syncErr.text || "").trim() || "core unreachable"
      }
    }
  }

  Process {
    id: actionProcess
    property string incidentId: ""
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.pendingAction = ""
      if (exitCode !== 0) root.actionError = String(actionErr.text || "").trim() || "the core refused"
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.refresh(); heartbeatProcess.running = true }
  }

  Timer {
    interval: 1000
    running: root.incidents.length > 0
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- heartbeats
  Process {
    id: heartbeatProcess
    running: false
    command: [root.binDir + "/alertroster-heartbeat", "check"]
    stdout: StdioCollector { id: heartbeatOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var overdue = []
      try { overdue = JSON.parse(String(heartbeatOut.text || "[]")) } catch (e) { return }
      for (var i = 0; i < overdue.length; i++) {
        var beat = overdue[i]
        root.page("No heartbeat from " + beat.name + " for " + Model.ageLabel(new Date(Date.now() - beat.silentFor * 1000).toISOString(), Date.now()), beat.urgency, "heartbeat")
      }
    }
  }

  // ---------------------------------------------------------------- alarm
  // Runs for exactly as long as something is paging. No timer here starts,
  // repeats or gives up on its own.
  Process {
    id: alarmProcess
    running: root.paging && root.soundEnabled
    command: ["mpv", "--no-terminal", "--no-video", "--loop-file=inf", "--volume=100", root.alarmFile]
  }

  // ---------------------------------------------------------------- takeover
  // One surface per output, above everything, for the incident that is
  // paging. Enter acknowledges. Escape, clicks and the close button do
  // nothing: dismiss requires an actual ack.
  Variants {
    model: root.takeoverEnabled && root.paging ? Quickshell.screens : []

    PanelWindow {
      id: takeover
      required property var modelData
      screen: modelData
      visible: true
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "alertroster-takeover"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      readonly property var incident: root.emergencyIncident
      readonly property color fg: Color.foreground
      readonly property color bg: Color.background
      readonly property color urgent: Color.urgent
      // Holds Enter inert for a moment after appearing, so a keypress already
      // on its way to whatever was on screen cannot acknowledge an emergency.
      property bool armed: false
      Timer { interval: 700; running: true; onTriggered: takeover.armed = true }

      Rectangle {
        anchors.fill: parent
        color: takeover.bg
        opacity: 0.96
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: takeover.urgent
        border.width: Style.space(10)
        SequentialAnimation on opacity {
          loops: Animation.Infinite
          NumberAnimation { from: 1.0; to: 0.25; duration: 600; easing.type: Easing.InOutSine }
          NumberAnimation { from: 0.25; to: 1.0; duration: 600; easing.type: Easing.InOutSine }
        }
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && takeover.armed && root.pendingAction === "") {
            root.acknowledgeEmergency()
          }
          event.accepted = true
        }

        Column {
          anchors.centerIn: parent
          width: Math.min(parent.width * 0.8, Style.space(900))
          spacing: Style.space(18)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "PAGING" + (takeover.incident && takeover.incident.escalate_at ? "   ·   " + Model.countdownLabel(takeover.incident.escalate_at, root.nowMs).toUpperCase() : "")
            color: takeover.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            font.letterSpacing: 4
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: takeover.incident ? takeover.incident.title : ""
            textFormat: Text.PlainText
            color: takeover.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge * 2.2
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: takeover.incident
              ? Model.sourceLabel(takeover.incident) + "   ·   triggered " + Model.ageLabel(takeover.incident.triggered_at, root.nowMs) + " ago"
                + (takeover.incident.escalation_repeat_count > 0 ? "   ·   escalation " + takeover.incident.escalation_repeat_count : "")
              : ""
            textFormat: Text.PlainText
            color: Qt.darker(takeover.fg, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }

          Item { width: 1; height: Style.space(16) }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: ackLabel.implicitWidth + Style.space(64)
            height: ackLabel.implicitHeight + Style.space(28)
            radius: Style.cornerRadius
            color: ackMouse.containsMouse ? Qt.darker(takeover.urgent, 1.2) : takeover.urgent
            opacity: takeover.armed ? 1 : 0.5
            Text {
              id: ackLabel
              anchors.centerIn: parent
              text: root.pendingAction !== "" ? "Acknowledging…" : "Acknowledge   ⏎"
              color: takeover.bg
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }
            MouseArea {
              id: ackMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: if (takeover.armed && root.pendingAction === "") root.acknowledgeEmergency()
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.actionError !== "" ? "Not acknowledged: " + root.actionError : "Escape does nothing. Dismiss requires an acknowledgement."
            textFormat: Text.PlainText
            color: root.actionError !== "" ? takeover.urgent : Qt.darker(takeover.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- IPC
  //   omarchy-shell alertroster.pager page "Deploy failed" high cli
  //   omarchy-shell alertroster.pager ack local-1
  //   omarchy-shell alertroster.pager status
  IpcHandler {
    target: "alertroster.pager"

    function page(title: string, urgency: string, source: string): string {
      return root.page(title, urgency, source)
    }
    function ack(id: string): string { return root.acknowledge(id) }
    function resolve(id: string): string { return root.resolve(id) }
    function ackAll(): string {
      var list = root.incidents
      for (var i = 0; i < list.length; i++) if (list[i].status === "triggered") root.acknowledge(list[i].id)
      return "ok"
    }
    function clear(): string { root.clearLocal(); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function test(): string {
      return root.page("Test page from the Omarchy shell", "high", "test")
    }
    function status(): string {
      return JSON.stringify({
        link: root.link,
        paging: root.paging,
        open: root.incidents.length,
        triggered: root.triggeredCount,
        lastSync: root.lastSyncMs > 0 ? new Date(root.lastSyncMs).toISOString() : null,
        error: root.lastError,
        incidents: root.incidents
      })
    }
  }
}
