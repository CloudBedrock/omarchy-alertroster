// Pure functions over the incident object. Nothing here holds state, runs a
// timer, or talks to the network — that is Service.qml's job.
//
// The incident shape is AlertRoster's (docs/INCIDENT_API.md §3). Local pages
// raised on this machine use the same shape so the widget, the panel and the
// takeover render one kind of thing. Local incidents carry `local: true` and
// an id that starts with "local-".

var OPEN = { triggered: true, acknowledged: true }

function isOpen(incident) {
  return !!(incident && OPEN[String(incident.status || "")])
}

function isLocal(incident) {
  return !!(incident && incident.local === true)
}

// The server decides `emergency` for its own incidents and the client must
// not second-guess it. For a local page there is no server, so the plugin
// applies the one rule the core applies today: paging until acknowledged
// when urgency is high. That is the whole of the local "policy".
function localEmergency(incident) {
  return incident.status === "triggered" && incident.urgency === "high"
}

function makeLocalIncident(serial, title, urgency, source, nowIso) {
  var u = String(urgency || "high").toLowerCase() === "low" ? "low" : "high"
  var incident = {
    id: "local-" + serial,
    local: true,
    status: "triggered",
    urgency: u,
    title: String(title || "").trim() || "Untitled page",
    dedup_key: null,
    source_id: null,
    source_name: String(source || "local"),
    triggered_at: nowIso,
    acknowledged_at: null,
    acknowledged_by_user_id: null,
    assigned_to_user_id: null,
    assigned_at: null,
    resolved_at: null,
    escalate_at: null,
    escalation_rule_position: 0,
    escalation_repeat_count: 0,
    emergency: false,
    available_actions: ["acknowledged", "resolved"]
  }
  incident.emergency = localEmergency(incident)
  return incident
}

function applyLocalTransition(incident, action, nowIso) {
  var next = {}
  for (var k in incident) next[k] = incident[k]
  if (action === "acknowledged" && incident.status === "triggered") {
    next.status = "acknowledged"
    next.acknowledged_at = nowIso
    next.available_actions = ["resolved"]
  } else if (action === "resolved" && isOpen(incident)) {
    next.status = "resolved"
    next.resolved_at = nowIso
    next.available_actions = []
  } else {
    return incident
  }
  next.emergency = localEmergency(next)
  return next
}

// GET /api/v1/incidents → array, or null when the body is not what we expect
// so the caller keeps the last good list rather than blanking the board.
function parseIncidentList(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !Array.isArray(data.incidents)) return null
    var out = []
    for (var i = 0; i < data.incidents.length; i++) {
      var inc = data.incidents[i]
      if (inc && typeof inc.id === "string") out.push(inc)
    }
    return out
  } catch (e) {
    return null
  }
}

// Unacknowledged first, then high urgency, then oldest first — the same order
// alertroster-desktop's board uses. Presentation only.
function sortForBoard(list) {
  var copy = list.slice()
  copy.sort(function(a, b) {
    var ta = a.status === "triggered" ? 0 : 1
    var tb = b.status === "triggered" ? 0 : 1
    if (ta !== tb) return ta - tb
    var ua = a.urgency === "high" ? 0 : 1
    var ub = b.urgency === "high" ? 0 : 1
    if (ua !== ub) return ua - ub
    return String(a.triggered_at || "") < String(b.triggered_at || "") ? -1 : 1
  })
  return copy
}

function openOnly(list) {
  var out = []
  for (var i = 0; i < list.length; i++) if (isOpen(list[i])) out.push(list[i])
  return out
}

function firstEmergency(list) {
  for (var i = 0; i < list.length; i++) if (list[i].emergency === true) return list[i]
  return null
}

function countTriggered(list) {
  var n = 0
  for (var i = 0; i < list.length; i++) if (list[i].status === "triggered") n++
  return n
}

function canAct(incident, action) {
  var actions = incident && Array.isArray(incident.available_actions) ? incident.available_actions : []
  return actions.indexOf(action) !== -1
}

function statusLabel(incident) {
  if (!incident) return ""
  if (incident.emergency) return "PAGING"
  switch (incident.status) {
    case "triggered": return "TRIGGERED"
    case "acknowledged": return "ACKNOWLEDGED"
    case "resolved": return "RESOLVED"
    case "auto_resolved": return "AUTO-RESOLVED"
    case "expired": return "EXPIRED — NOBODY ANSWERED"
  }
  return String(incident.status || "").toUpperCase()
}

function ageLabel(isoTime, nowMs) {
  var t = Date.parse(String(isoTime || ""))
  if (isNaN(t)) return ""
  var s = Math.max(0, Math.floor((nowMs - t) / 1000))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m " + (s % 60) + "s"
  var h = Math.floor(m / 60)
  if (h < 48) return h + "h " + (m % 60) + "m"
  return Math.floor(h / 24) + "d"
}

function countdownLabel(isoTime, nowMs) {
  var t = Date.parse(String(isoTime || ""))
  if (isNaN(t)) return ""
  var s = Math.floor((t - nowMs) / 1000)
  if (s <= 0) return "escalating"
  var m = Math.floor(s / 60)
  var r = s % 60
  return "escalates in " + m + ":" + (r < 10 ? "0" : "") + r
}

function sourceLabel(incident) {
  if (!incident) return ""
  if (incident.source_name) return String(incident.source_name)
  if (incident.local) return "local"
  return "alertroster"
}

// Bar pill text. Empty means "show just the icon".
function pillText(openList) {
  var triggered = countTriggered(openList)
  if (triggered > 0) return String(triggered)
  return openList.length > 0 ? String(openList.length) : ""
}

function barIcon(openList, emergency) {
  if (emergency) return "󰂞"
  if (countTriggered(openList) > 0) return "󰂚"
  if (openList.length > 0) return "󰂜"
  return "󰂚"
}
