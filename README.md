# AlertRoster Pager for Omarchy

Your desktop should be able to page you.

A bell in the bar that goes red when something needs a human, a full-screen
takeover you can only clear by acknowledging, and a two-tone alarm that runs
for exactly as long as the page does. It works with nothing but Omarchy
installed. Run the AlertRoster receiver service and the same takeover answers
for Home Assistant, a wall display and a siren in the garage; sign in to
[AlertRoster](https://alertroster.com) and it reaches your whole roster —
phones, escalation, on-site beacons.

![The takeover](preview.png)

## Install

```bash
omarchy plugin add https://github.com/cloudbedrock/omarchy-alertroster.git --enable
```

Then put the helper scripts on your `PATH` (or call them by full path):

```bash
ln -s ~/.config/omarchy/plugins/alertroster.pager/bin/alertroster-* ~/.local/bin/
```

Needs `curl`, `jq`, `secret-tool`, `mpv` and `python3` — all already on an
Omarchy install.

## Page yourself

```bash
alertroster-page "Database is down"               # takes over the screen until you press Enter
alertroster-page --low "Backup finished, 2 warnings"   # red count in the bar + a notification
alertroster-page --detail "exit 137 in step 4" "Deploy failed on $(hostname)"
make deploy || alertroster-page "Deploy failed on $(hostname)"
```

From anything that can hit a shell:

```bash
omarchy-shell alertroster.pager page "Title" high my-source
omarchy-shell alertroster.pager status | jq
```

### Dead-man's switch

Page yourself when something *stops* happening.

```bash
alertroster-heartbeat expect nightly-backup 26h    # page if it goes quiet
alertroster-heartbeat ping nightly-backup          # put this at the end of the job
alertroster-heartbeat list
```

### Webhooks from your monitoring

Point Uptime Kuma, Grafana, Healthchecks.io or anything with a "run a
command" step at `alertroster-page`. For anything that speaks HTTP, run the
receiver service (below) and let it pair: it is the one thing on this machine
that is allowed to listen for pages, and nothing pages it without a token.

## The receiver service

[AlertRoster desktop](https://github.com/CloudBedrock/alertroster-desktop-releases/releases/latest)
ships `alertroster-receiverd`,
a headless service that holds every pending acknowledgement for this machine:
who fired it, how long it has gone unanswered, who answered and when. When it
is running, this plugin is one of its *surfaces* — it renders what the
service holds, and an acknowledgement goes back to the service with your
username. That is what lets one page reach everything you own at once:

- **Home Assistant** pairs with the service and raises alerts from any
  automation. The takeover on your Omarchy box, the wall display and the
  siren on a relay all fire together, and the first acknowledgement stands
  them all down. If nobody answers before the alert's timeout, HA gets an
  `alertroster_unacknowledged` event to branch on.
- **`alertroster-page`** raises its pages on the service too, so they get the
  same timeout, the same fan-out and the same record.
- **Heartbeats** that lapse become alerts on the service, not pages the
  plugin holds by itself.

**[Download the receiver station →](https://github.com/CloudBedrock/alertroster-desktop-releases/releases/latest)**
— free, and it runs on this machine, a Mac, a Windows box or a Raspberry Pi on
the wall. You do not need it to page yourself; you need it for everything in
the list above.

Nothing changes in how you use it. The plugin finds the service on loopback
(`127.0.0.1:4747`) through the token file it writes for its own user, starts
it if it is installed but not running, and falls back to holding pages itself
when there is no service at all. The panel header says which it is doing.

A service on another machine — a NAS, the box under the TV — works too:

```bash
alertroster-page --pair 48213907 --station http://kitchen-pc:4747   # code from that station's Pairing screen
alertroster-page "Backup failed"                                    # now lands there
alertroster-page --unpair
```

Off-site escalation is the service's job as well: give it an integration key
(desktop → Service → Cloud…) and every alert it holds is also opened on your
AlertRoster account, with the local timeout as the grace period before the
roster's phones ring. The plugin shows when that forward did not happen.

## Keys

In the panel (click the bell): `j`/`k` move · `a` or Enter acknowledge · `r`
resolve · `R` refresh · `t` test page · Esc close.

On the takeover: **Enter acknowledges. Nothing else closes it.** Escape,
clicking, and the window manager do nothing — that is the point.

## Sign in to page your roster

```bash
alertroster-login                          # email → one-time code → tokens in your keyring
alertroster-login --sync-key ark_sync_…    # an integration key for a source on your account
alertroster-page --remote "Kamal deploy failed"
```

Once signed in the bar also mirrors your account's open incidents, the
takeover fires when the core says an incident is paging *you*, and
acknowledging from the desktop stops the escalation for everyone — on phones,
on other workstations, and on any AlertRoster hardware receivers in the room.
`--remote` raises the page on your account through a source's integration
key, so it escalates to the roster if you do not answer.

The plugin is a thin client. It renders what the receiver service or the core
sends — `emergency`, `available_actions`, `status` — and decides none of them.
Only when there is no service does it hold pages itself, and then the one rule
applied is: high urgency pages until acknowledged. No timeouts, no escalation,
no roster, no phones.

## Settings

Setup → Bar → Pager: account sync / heartbeat interval, alarm on/off, takeover
on/off, hide the bell when nothing is open.

## Files this touches

- `$XDG_RUNTIME_DIR/alertroster/surface.token` — read, never written: the receiver service's surface token
- `~/.config/alertroster/host` — the AlertRoster host (default `https://alertroster.com`)
- `~/.config/alertroster/station` — a receiver service on another machine, after `--pair`
- `~/.config/alertroster/heartbeats.json` — what you told it to expect
- `~/.local/state/alertroster/heartbeats/` — last-ping stamps
- your keyring (`secret-tool`, service `alertroster`) — tokens; nothing in the clear

Remove everything with `omarchy plugin remove alertroster.pager`,
`alertroster-page --unpair` and `alertroster-login --logout`.

## Tests

```bash
tests/run.sh                                         # Model.js, the scripts
ALERTROSTER_RECEIVERD=/path/to/alertroster-receiverd tests/run.sh   # + the surface link against a real service
```

---

AlertRoster is a call-out notification and escalation tool. It notifies
people who have agreed in advance to be notified, and records what happened.
It is not an emergency service and does not contact one on your behalf. It is
not a fire alarm, a security alarm, or an alarm monitoring service, and it
holds no life-safety certification. It is not a replacement for your team's
official paging arrangements, and it should not be the only way a call-out
can reach your people.

MIT © Cloud Bedrock LLC
