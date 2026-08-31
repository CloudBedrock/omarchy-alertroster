// Unit tests for Model.js — the pure functions the widget, panel and takeover
// render from. Run with: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { deepEqual as looseDeepEqual } from "node:assert" // arrays from the vm context have their own Array prototype
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const Model = vm.createContext({})
vm.runInContext(readFileSync(join(here, "..", "Model.js"), "utf8"), Model)

const serviceAlert = (over = {}) => ({
  id: "la_01J5Y4V8K0Q2M7R9T3A6B1C4D8",
  status: "triggered",
  urgency: "high",
  title: "Garage door open after midnight",
  detail: "Left open 14 min",
  dedup_key: "garage",
  source: { id: "src_ha", name: "Home Assistant", kind: "homeassistant" },
  triggered_at: "2026-08-25T03:04:00Z",
  ack_timeout_seconds: 120,
  expires_at: "2026-08-25T03:06:00Z",
  acknowledged_at: null,
  acknowledged_by: null,
  resolved_at: null,
  emergency: true,
  available_actions: ["acknowledged", "resolved"],
  cloud: null,
  ...over,
})

test("service alerts are tagged, never re-derived", () => {
  const tagged = Model.tagServiceAlert(serviceAlert({ emergency: false }))
  assert.equal(tagged.service, true)
  assert.equal(Model.isService(tagged), true)
  assert.equal(Model.laneOf(tagged), "service")
  // The service said not-emergency for a triggered high alert; we keep that.
  assert.equal(tagged.emergency, false)
  assert.equal(Model.tagServiceAlert({ title: "no id" }), null)
  assert.equal(Model.alertsFrom("nope"), null)
  looseDeepEqual(Model.alertsFrom([serviceAlert(), { bad: true }]).map(a => a.id), [serviceAlert().id])
})

test("upsertOpen replaces, appends and drops closed alerts", () => {
  const a = Model.tagServiceAlert(serviceAlert())
  const b = Model.tagServiceAlert(serviceAlert({ id: "la_b", title: "B" }))
  let list = Model.upsertOpen([], a)
  list = Model.upsertOpen(list, b)
  looseDeepEqual(list.map(x => x.id), [a.id, "la_b"])
  const acked = Model.tagServiceAlert(serviceAlert({ status: "acknowledged", emergency: false, available_actions: ["resolved"] }))
  list = Model.upsertOpen(list, acked)
  assert.equal(list[0].status, "acknowledged")
  assert.equal(list.length, 2)
  list = Model.upsertOpen(list, Model.tagServiceAlert(serviceAlert({ id: "la_b", status: "expired", emergency: false, available_actions: [] })))
  looseDeepEqual(list.map(x => x.id), [a.id])
  // A closed alert we never saw does not get added either.
  list = Model.upsertOpen(list, Model.tagServiceAlert(serviceAlert({ id: "la_c", status: "resolved" })))
  assert.equal(list.length, 1)
})

test("local fallback applies the one rule and nothing else", () => {
  const inc = Model.makeLocalIncident(1, "  Deploy failed ", "HIGH", "cli", "2026-08-25T00:00:00Z")
  assert.equal(inc.id, "local-1")
  assert.equal(inc.local, true)
  assert.equal(inc.title, "Deploy failed")
  assert.equal(inc.emergency, true)
  const low = Model.makeLocalIncident(2, "", "low", null, "2026-08-25T00:00:00Z")
  assert.equal(low.title, "Untitled page")
  assert.equal(low.emergency, false)
  const acked = Model.applyLocalTransition(inc, "acknowledged", "2026-08-25T00:01:00Z")
  assert.equal(acked.status, "acknowledged")
  assert.equal(acked.emergency, false)
  looseDeepEqual(acked.available_actions, ["resolved"])
  assert.equal(Model.applyLocalTransition(acked, "acknowledged", "x"), acked)
  const resolved = Model.applyLocalTransition(acked, "resolved", "2026-08-25T00:02:00Z")
  assert.equal(Model.isOpen(resolved), false)
})

test("board order: triggered, then high, then oldest", () => {
  const list = [
    { id: "1", status: "acknowledged", urgency: "high", triggered_at: "2026-01-01T00:00:00Z" },
    { id: "2", status: "triggered", urgency: "low", triggered_at: "2026-01-01T00:00:00Z" },
    { id: "3", status: "triggered", urgency: "high", triggered_at: "2026-01-01T00:00:05Z" },
    { id: "4", status: "triggered", urgency: "high", triggered_at: "2026-01-01T00:00:01Z" },
  ]
  looseDeepEqual(Model.sortForBoard(list).map(x => x.id), ["4", "3", "2", "1"])
})

test("labels render what the service sent", () => {
  const alert = Model.tagServiceAlert(serviceAlert({
    status: "acknowledged", emergency: false,
    acknowledged_by: { surface: "local", name: "kitchen-pc", user: "jim" },
    cloud: { incident_id: "x", status: "triggered", escalate_at: "2026-08-25T03:06:00Z", assigned_to: null, link: "failed" },
  }))
  assert.equal(Model.sourceLabel(alert), "Home Assistant")
  assert.equal(Model.ackedByLabel(alert), "acknowledged by jim on kitchen-pc")
  assert.equal(Model.cloudLabel(alert), "OFF-SITE ESCALATION FAILED")
  assert.equal(Model.cloudFailed(alert), true)
  assert.equal(Model.escalateAt(alert), "2026-08-25T03:06:00Z")
  assert.equal(Model.ackedByLabel({ acknowledged_by: { surface: "cloud", name: "core", user: "u_1" } }), "acknowledged by u_1 from the roster")
  assert.equal(Model.cloudLabel(serviceAlert()), "")
  assert.equal(Model.escalateAt(serviceAlert()), null)  // expires_at is never a countdown
  assert.equal(Model.statusLabel({ status: "expired" }), "EXPIRED — NOBODY ANSWERED")
  assert.equal(Model.sourceLabel({ source_name: "cli", local: true }), "cli")
  assert.equal(Model.sourceLabel({ local: true }), "local")
  assert.equal(Model.sourceLabel({}), "alertroster")
})

test("panel header labels", () => {
  assert.equal(Model.surfaceLabel("live"), "Receiver service attached")
  assert.match(Model.surfaceLabel("down"), /last known state/)
  assert.match(Model.surfaceLabel("absent"), /held by the shell/)
  assert.match(Model.surfaceLabel(undefined), /held by the shell/)
  assert.equal(Model.cloudLinkLabel("local"), "")
  assert.equal(Model.cloudLinkLabel("connected"), "AlertRoster connected")
})

test("bar pill and icon", () => {
  const open = [{ status: "triggered" }, { status: "acknowledged" }]
  assert.equal(Model.pillText(open), "1")
  assert.equal(Model.pillText([{ status: "acknowledged" }]), "1")
  assert.equal(Model.pillText([]), "")
  assert.equal(Model.barIcon(open, true), "󰂞")
  assert.equal(Model.firstEmergency([{ emergency: false }, { emergency: true, id: "e" }]).id, "e")
  assert.equal(Model.countTriggered(open), 1)
  assert.equal(Model.canAct({ available_actions: ["resolved"] }, "acknowledged"), false)
  assert.equal(Model.canAct({ available_actions: ["resolved"] }, "resolved"), true)
})

test("cloud incident list parsing keeps the last good list on junk", () => {
  assert.equal(Model.parseIncidentList("not json"), null)
  assert.equal(Model.parseIncidentList('{"nope":[]}'), null)
  looseDeepEqual(Model.parseIncidentList('{"incidents":[{"id":"a"},{"x":1}]}').map(i => i.id), ["a"])
})
