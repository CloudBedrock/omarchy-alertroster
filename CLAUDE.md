# CLAUDE.md

Omarchy Quattro plugin `alertroster.pager` (QML: `Service.qml`, `BarWidget.qml`, `Model.js`; helper scripts in `bin/`). Public, MIT. It is a *surface* of `alertroster-receiverd` (closed source, lives in `alertroster-desktop`) when one runs, and holds pages itself only when none does. Never vendor or link desktop/firmware source here.

## Pre-commit

```bash
tests/run.sh                                                      # scripts parse, Model.js unit tests
ALERTROSTER_RECEIVERD=~/dev/alertroster-desktop/build/linux/alertroster-receiverd tests/run.sh   # + surface bridge and CLI against a real service
```

`qmllint -I /usr/lib/qt6/qml -I /usr/share/omarchy/shell Service.qml BarWidget.qml` and `omarchy-plugin-validate "$PWD"` must exit 0.

## Rules

- Thin client: `emergency`, `status`, `available_actions` are rendered as the service or the core sent them, never derived. The only local rule is the fallback's "high + triggered = paging until acknowledged".
- The takeover comes down on the `emergency: false` delta, never because a button was pressed.
- No open LAN endpoint in this repo. Pairing and listening are the receiver service's job.
- Issue refs name the project (`omarchy-alertroster#1`, `alertroster-desktop#54`).
