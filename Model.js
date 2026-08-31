// Pure functions over the incident object. Nothing here holds state, runs a
// timer, or talks to the network — that is Service.qml's job.
//
// Three kinds of thing cross this plugin, and they share one shape so the
// widget, the panel and the takeover render one kind of thing:
//
//   service  — an alert held by the receiver service (alertroster-receiverd),
//              LOCAL_ACK_PROTOCOL.md §2.1. Field names match the incident
//              object where the meaning is identical. Tagged `service: true`.
//   local    — a page raised on this machine while no service answers; the
//              embedded fallback. Tagged `local: true`, id starts "local-".
//   cloud    — an incident from your AlertRoster account (INCIDENT_API.md §3).
//
// `emergency` and `available_actions` are decided by whoever holds the
// object — the service, the core — and rendered here as sent. The one
// exception is the local fallback, where there is nobody else to decide.

var OPEN = { triggered: true, acknowledged: true }

function isOpen(incident) {
  return !!(incident && OPEN[String(incident.status || "")])
}

function isLocal(incident) {
  return !!(incident && incident.local === true)
}

function isService(incident) {
  return !!(incident && incident.service === true)
}

function laneOf(incident) {
  if (isLocal(incident)) return "local"
  if (isService(incident)) return "service"
  return "cloud"
}

// ---------------------------------------------------------------- local fallback

// With no service there is nobody to decide `emergency`, so the plugin
// applies the one rule the service applies (§2.1): paging until acknowledged
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
    detail: null,
    dedup_key: null,
    source_id: null,
    source_name: String(source || "local"),
    triggered_at: nowIso,
    acknowledged_at: null,
    acknowledged_by: null,
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

// ---------------------------------------------------------------- service alerts

// An alert as the service sent it, tagged so the rest of the plugin can tell
// which lane it came down. Nothing is derived: `emergency`, `status` and
// `available_actions` are the service's.
function tagServiceAlert(alert) {
  if (!alert || typeof alert.id !== "string") return null
  var copy = {}
  for (var k in alert) copy[k] = alert[k]
  copy.service = true
  return copy
}

// The `alerts` array of a snapshot frame → tagged list, or null when the
// frame is not what we expect so the caller keeps what it has.
function alertsFrom(list) {
  if (!Array.isArray(list)) return null
  var out = []
  for (var i = 0; i < list.length; i++) {
    var tagged = tagServiceAlert(list[i])
    if (tagged) out.push(tagged)
  }
  return out
}

// Apply one delta to the open list: replace by id, append if new, drop when
// the alert has closed. The result is always the open set and nothing else.
function upsertOpen(list, alert) {
  var out = []
  var seen = false
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === alert.id) {
      seen = true
      if (isOpen(alert)) out.push(alert)
    } else {
      out.push(list[i])
    }
  }
  if (!seen && isOpen(alert)) out.push(alert)
  return out
}

function findById(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// ---------------------------------------------------------------- cloud incidents

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

// ---------------------------------------------------------------- the board

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

// ---------------------------------------------------------------- labels

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

// When the core will escalate, from whichever lane carries the core's view:
// the incident's own `escalate_at`, or the service alert's `cloud.escalate_at`
// (§7.2). The local `expires_at` is deliberately not rendered as a countdown —
// the service's `expired` transition is what a surface acts on (§2.1).
function escalateAt(incident) {
  if (!incident) return null
  if (incident.escalate_at) return incident.escalate_at
  if (incident.cloud && incident.cloud.escalate_at) return incident.cloud.escalate_at
  return null
}

function sourceLabel(incident) {
  if (!incident) return ""
  if (incident.source && typeof incident.source === "object" && incident.source.name) return String(incident.source.name)
  if (incident.source_name) return String(incident.source_name)
  if (incident.local) return "local"
  return "alertroster"
}

// §7.2: `cloud.link == "failed"` must be rendered by every surface — the user
// paid for off-site escalation and needs to know when it did not happen.
function cloudLabel(incident) {
  if (!incident || !incident.cloud || typeof incident.cloud !== "object") return ""
  switch (String(incident.cloud.link || "")) {
    case "failed": return "OFF-SITE ESCALATION FAILED"
    case "pending": return "sending off-site"
    case "ok": return incident.cloud.assigned_to ? "assigned off-site" : "escalating off-site"
  }
  return ""
}

function cloudFailed(incident) {
  return !!(incident && incident.cloud && incident.cloud.link === "failed")
}

// "acknowledged by jim on Kitchen PC" — §2.1's `acknowledged_by`, recorded
// by the service, rendered as sent.
function ackedByLabel(incident) {
  if (!incident || !incident.acknowledged_by || typeof incident.acknowledged_by !== "object") return ""
  var by = incident.acknowledged_by
  var who = by.user ? String(by.user) : ""
  var where = by.surface === "cloud" ? "from the roster" : (by.name ? "on " + by.name : "")
  var parts = []
  if (who) parts.push(who)
  if (where) parts.push(where)
  return parts.length ? "acknowledged by " + parts.join(" ") : ""
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

// The receiver-service link, for the panel header. `surface` is the bridge's
// link state (bin/alertroster-surface).
function surfaceLabel(surface) {
  switch (String(surface || "")) {
    case "live": return "Receiver service attached"
    case "down": return "Receiver service link down — showing last known state"
    case "starting": return "Waiting for the receiver service"
    case "unauthorized": return "Receiver service refused the surface token"
  }
  return "No receiver service — pages held by the shell"
}

function cloudLinkLabel(link) {
  switch (String(link || "")) {
    case "connected": return "AlertRoster connected"
    case "offline": return "AlertRoster unreachable — showing last sync"
    case "unauthorized": return "Signed out — run alertroster-login"
  }
  return ""
}
