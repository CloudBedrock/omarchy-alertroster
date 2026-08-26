# AlertRoster Pager for Omarchy

Your desktop should be able to page you.

A bell in the bar that goes red when something needs a human, a full-screen
takeover you can only clear by acknowledging, and a two-tone alarm that runs
for exactly as long as the page does. It works with nothing but Omarchy
installed; sign in to [AlertRoster](https://alertroster.com) and the same
pager reaches your whole roster — phones, escalation, on-site beacons.

![The takeover](preview.png)

## Install

```bash
omarchy plugin add https://github.com/cloudbedrock/omarchy-alertroster.git --enable
```

Then put the helper scripts on your `PATH` (or call them by full path):

```bash
ln -s ~/.config/omarchy/plugins/alertroster.pager/bin/alertroster-* ~/.local/bin/
```

## Page yourself

```bash
alertroster-page "Database is down"               # takes over the screen until you press Enter
alertroster-page --low "Backup finished, 2 warnings"   # red count in the bar + a notification
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
command" / webhook step at `alertroster-page`. A one-line `socat` listener
turns HTTP into pages:

```bash
socat TCP-LISTEN:4747,reuseaddr,fork SYSTEM:'read l; alertroster-page "$(sed -n "s/.*title=//p" <<<"$l")"'
```

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

Once signed in the bar mirrors your account's open incidents, the takeover
fires when the core says an incident is paging *you*, and acknowledging from
the desktop stops the escalation for everyone — on phones, on other
workstations, and on any AlertRoster hardware receivers in the room.
`--remote` raises the page on your account through a source's integration
key, so it escalates to the roster if you do not answer.

The plugin is a thin client. For incidents from AlertRoster it renders what
the core sends — `emergency`, `available_actions`, `status` — and decides none
of them. For local pages there is no core, so the one rule applied is: high
urgency pages until acknowledged. No escalation, no roster, no phones.

## Settings

Setup → Bar → Pager: refresh interval, alarm on/off, takeover on/off, hide the
bell when nothing is open.

## Files this touches

- `~/.config/alertroster/host` — the AlertRoster host (default `https://alertroster.com`)
- `~/.config/alertroster/heartbeats.json` — what you told it to expect
- `~/.local/state/alertroster/heartbeats/` — last-ping stamps
- your keyring (`secret-tool`, service `alertroster`) — tokens; nothing in the clear

Remove everything with `omarchy plugin remove alertroster.pager` and
`alertroster-login --logout`.

---

AlertRoster is a call-out notification and escalation tool. It notifies
people who have agreed in advance to be notified, and records what happened.
It is not an emergency service and does not contact one on your behalf. It is
not a fire alarm, a security alarm, or an alarm monitoring service, and it
holds no life-safety certification. It is not a replacement for your team's
official paging arrangements, and it should not be the only way a call-out
can reach your people.

MIT © Cloud Bedrock LLC
