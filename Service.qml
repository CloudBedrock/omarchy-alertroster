import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// The pager. One instance for the whole shell; renders the open alert set,
// raises the takeover, loops the alarm, and answers IPC.
//
// It is a surface of the receiver service (alertroster-receiverd,
// LOCAL_ACK_PROTOCOL.md §5) when one is running: bin/alertroster-surface
// holds the socket, this renders the snapshot and every delta, and an
// acknowledgement goes back over that socket with the user's name. The
// takeover comes down because the service's next delta carries
// `emergency: false` — never because a button was pressed.
//
// With no service on the machine it falls back to holding pages itself, so
// `alertroster-page` works on a box with nothing but Omarchy installed. That
// embedded store applies the one rule the service applies (high + triggered
// = paging until acknowledged) and nothing more: no timeouts, no escalation,
// no roster. Signed in, it also mirrors your account's open incidents.
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
  readonly property string user: Quickshell.env("USER") || ""

  // ---------------------------------------------------------------- state
  // What the receiver service holds, from its snapshot and deltas.
  property var serviceAlerts: []
  // The embedded fallback: pages raised while no service answers.
  property var localIncidents: []
  property int localSerial: 0
  // Your account's open incidents, when signed in.
  property var remoteIncidents: []

  // The surface link, as bin/alertroster-surface reports it:
  // "live" — attached, the board is true; "down" — was live, re-dialling,
  // the board is stale; "starting" — a service is expected but not answering
  // yet; "unauthorized" — the token on disk was refused; "absent" — nothing
  // to attach to, pages are held here.
  property string surface: "absent"
  property string surfaceDetail: ""
  readonly property bool attached: surface === "live"
  property bool snapshotSeen: false

  // The cloud link: "local" — not signed in; "connected"; "offline" — signed
  // in but the core is unreachable; "unauthorized" — tokens dead.
  property string link: "local"
  property string lastError: ""
  property double lastSyncMs: 0
  property bool syncing: false
  property double nowMs: Date.now()

  readonly property var incidents: Model.sortForBoard(Model.openOnly(localIncidents).concat(Model.openOnly(serviceAlerts)).concat(Model.openOnly(remoteIncidents)))
  readonly property var emergencyIncident: Model.firstEmergency(incidents)
  readonly property bool paging: emergencyIncident !== null
  readonly property int triggeredCount: Model.countTriggered(incidents)

  readonly property bool soundEnabled: setting("sound", true) === true
  readonly property bool takeoverEnabled: setting("takeover", true) === true
  readonly property int refreshIntervalSec: Math.max(2, Math.min(300, parseInt(String(setting("refreshIntervalSec", 5)), 10) || 5))

  // Set while an ack/resolve is in flight, so the takeover can say so —
  // nothing else is visible while it is up.
  property string pendingAction: ""
  property string pendingId: ""
  property string actionError: ""

  signal incidentOpened(var incident)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function nowIso() { return new Date().toISOString() }

  // ---------------------------------------------------------------- pages
  // Attached, a page is raised on the service like any other source's and
  // comes back down the socket; the id is not known until then. Otherwise
  // the embedded store holds it.
  function page(title, urgency, source) {
    if (attached) {
      raiseQueue.push({ title: String(title || ""), urgency: String(urgency || "high"), source: String(source || "shell") })
      raiseNext()
      return "sent"
    }
    return pageLocally(title, urgency, source)
  }

  function pageLocally(title, urgency, source) {
    localSerial += 1
    var incident = Model.makeLocalIncident(localSerial, title, urgency, source, nowIso())
    localIncidents = localIncidents.concat([incident])
    announce(incident)
    return incident.id
  }

  property var raiseQueue: []
  function raiseNext() {
    if (raiseProcess.running || raiseQueue.length === 0) return
    var next = raiseQueue.shift()
    raiseProcess.request = next
    raiseProcess.command = [binDir + "/alertroster-local", "POST", "/v1/alerts",
      JSON.stringify({ title: next.title, urgency: next.urgency === "low" ? "low" : "high",
                       detail: "Raised through the Omarchy shell (" + next.source + ")" })]
    raiseProcess.running = true
  }

  Process {
    id: raiseProcess
    property var request: ({})
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: raiseErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // The service did not take it. The page must still land somewhere.
        root.lastError = "Receiver service refused a page: " + (String(raiseErr.text || "").trim() || "exit " + exitCode)
        root.pageLocally(request.title, request.urgency, request.source)
      }
      root.raiseNext()
    }
  }

  function announce(incident) {
    incidentOpened(incident)
    if (incident.emergency && takeoverEnabled) return // the takeover *is* the notification
    notify(incident.urgency === "high" ? "critical" : "normal", incident.title,
           Model.sourceLabel(incident) + " · " + Model.statusLabel(incident).toLowerCase())
  }

  function notify(urgency, title, body) {
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      "--app-name", "AlertRoster",
      "-g", "󰂞",
      "-u", urgency,
      title,
      body
    ])
  }

  function findIncident(id) {
    return Model.findById(localIncidents, id) || Model.findById(serviceAlerts, id) || Model.findById(remoteIncidents, id)
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
    if (Model.isService(incident)) {
      // Over the surface socket, with who answered (§5). The delta that
      // follows is what changes the board; an error frame is what says no.
      if (!attached) {
        actionError = "receiver service unreachable — not acknowledged"
        return "offline"
      }
      pendingAction = action
      pendingId = id
      actionError = ""
      var frame = { action: action === "acknowledged" ? "acknowledge" : "resolve", id: id }
      if (frame.action === "acknowledge") frame.user = user
      surfaceProcess.write(JSON.stringify(frame) + "\n")
      pendingTimeout.restart()
      return "sent"
    }
    // Cloud: ask the core, then re-sync. The takeover comes down when the
    // core stops flagging the incident, not because a button was pressed.
    if (actionProcess.running) return "busy"
    pendingAction = action
    pendingId = id
    actionError = ""
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

  function settlePending() {
    pendingAction = ""
    pendingId = ""
    pendingTimeout.stop()
  }

  Timer {
    id: pendingTimeout
    interval: 6000
    onTriggered: {
      if (root.pendingAction === "" || !Model.isService(root.findIncident(root.pendingId) || {})) return
      root.actionError = "no answer from the receiver service"
      root.settlePending()
    }
  }

  function clearLocal() {
    localIncidents = []
    // A board the service is no longer answering for is not one this
    // machine can act on; `clear` is the escape hatch that drops it.
    if (!attached) serviceAlerts = []
  }

  // ---------------------------------------------------------------- surface
  // bin/alertroster-surface holds the socket to the receiver service and
  // speaks JSON lines: every frame the service sends on stdout, every action
  // we write on stdin. It re-dials on its own and reports the link state.
  Process {
    id: surfaceProcess
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onSurfaceFrame(line) } }
    stderr: SplitParser { onRead: function(line) { if (String(line).trim() !== "") console.warn(line) } }
    onExited: function(exitCode) {
      root.applyLink("absent", "alertroster-surface exited (" + exitCode + ")")
      surfaceRestart.start()
    }
  }

  Timer {
    id: surfaceRestart
    interval: 5000
    onTriggered: root.startSurface()
  }

  function startSurface() {
    if (surfaceProcess.running) return
    surfaceProcess.command = [binDir + "/alertroster-surface"]
    surfaceProcess.running = true
  }

  Component.onCompleted: startSurface()

  function onSurfaceFrame(line) {
    var frame
    try { frame = JSON.parse(String(line)) } catch (e) { return }
    if (!frame || typeof frame !== "object") return
    switch (String(frame.event || "")) {
      case "link":
        applyLink(String(frame.state || "absent"), String(frame.detail || ""))
        return
      case "snapshot": {
        var list = Model.alertsFrom(frame.alerts)
        if (list === null) return
        // Announce what is new to this machine on a re-snapshot; on the
        // first one the takeover speaks for whatever is already paging.
        var fresh = []
        if (snapshotSeen) for (var i = 0; i < list.length; i++) if (!Model.findById(serviceAlerts, list[i].id)) fresh.push(list[i])
        serviceAlerts = list
        snapshotSeen = true
        for (var j = 0; j < fresh.length; j++) announce(fresh[j])
        return
      }
      case "alert.triggered":
      case "alert.acknowledged":
      case "alert.resolved":
      case "alert.updated":
      case "alert.expired": {
        var alert = Model.tagServiceAlert(frame.alert)
        if (!alert) return
        var known = Model.findById(serviceAlerts, alert.id) !== null
        serviceAlerts = Model.upsertOpen(serviceAlerts, alert)
        if (pendingId === alert.id) settlePending()
        if (frame.event === "alert.triggered" && !known) announce(alert)
        // §3: expired is the outcome the product exists to prevent, and a
        // surface must render it distinctly, never as an ordinary close.
        if (frame.event === "alert.expired") notify("critical", "Nobody answered: " + alert.title, Model.sourceLabel(alert) + " · expired unacknowledged")
        return
      }
      case "error":
        if (String(frame.id || "") === pendingId && pendingId !== "") {
          actionError = describeSurfaceError(String(frame.error || ""))
          settlePending()
        }
        return
    }
  }

  function describeSurfaceError(code) {
    switch (code) {
      case "link_down": return "receiver service unreachable — not acknowledged"
      case "invalid_transition": return "the service refused the transition"
      case "not_found": return "the service no longer holds that alert"
    }
    return "the receiver service refused: " + (code || "unknown")
  }

  function applyLink(state, detail) {
    var was = surface
    surface = state
    surfaceDetail = detail
    if (state === "absent" && serviceAlerts.length > 0) {
      // Nothing is answering for these any more. Say so once, then let the
      // board stop showing them as live.
      notify("normal", "Receiver service went away", serviceAlerts.length + " alert(s) dropped from the board — " + detail)
      serviceAlerts = []
    }
    if (state === "absent") snapshotSeen = false
    if (state !== "live" && pendingAction !== "" && Model.isService(findIncident(pendingId) || {})) {
      actionError = "receiver service unreachable — not acknowledged"
      settlePending()
    }
    if (was !== "live" && state === "live") lastError = ""
  }

  // ---------------------------------------------------------------- cloud sync
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
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.settlePending()
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
  // `check` raises a page for every beat gone overdue through
  // alertroster-page, so a lapsed heartbeat is a source of the receiver
  // service like any other page — and lands here only when there is none.
  Process {
    id: heartbeatProcess
    running: false
    command: [root.binDir + "/alertroster-heartbeat", "check"]
    stdout: SplitParser { onRead: function(line) {} }
    stderr: SplitParser { onRead: function(line) { if (String(line).trim() !== "") console.warn("alertroster-heartbeat: " + line) } }
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
            text: "PAGING" + (takeover.incident && Model.escalateAt(takeover.incident) ? "   ·   " + Model.countdownLabel(Model.escalateAt(takeover.incident), root.nowMs).toUpperCase() : "")
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
            visible: text !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: takeover.incident && takeover.incident.detail ? String(takeover.incident.detail) : ""
            textFormat: Text.PlainText
            color: Qt.darker(takeover.fg, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: takeover.incident
              ? Model.sourceLabel(takeover.incident) + "   ·   triggered " + Model.ageLabel(takeover.incident.triggered_at, root.nowMs) + " ago"
                + (takeover.incident.escalation_repeat_count > 0 ? "   ·   escalation " + takeover.incident.escalation_repeat_count : "")
                + (Model.cloudLabel(takeover.incident) !== "" ? "   ·   " + Model.cloudLabel(takeover.incident) : "")
              : ""
            textFormat: Text.PlainText
            color: Model.cloudFailed(takeover.incident) ? takeover.urgent : Qt.darker(takeover.fg, 1.4)
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
            text: root.actionError !== ""
              ? "Not acknowledged: " + root.actionError
              : (Model.isService(takeover.incident) && !root.attached
                  ? "Receiver service link is down — an acknowledgement cannot be recorded until it is back."
                  : "Escape does nothing. Dismiss requires an acknowledgement.")
            textFormat: Text.PlainText
            color: root.actionError !== "" || (Model.isService(takeover.incident) && !root.attached) ? takeover.urgent : Qt.darker(takeover.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- IPC
  //   omarchy-shell alertroster.pager page "Deploy failed" high cli
  //   omarchy-shell alertroster.pager ack la_01J…   (or local-1)
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
        surface: root.surface,
        surfaceDetail: root.surfaceDetail,
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
