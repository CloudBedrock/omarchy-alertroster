#!/usr/bin/env python3
"""Integration test: the surface bridge and the CLI against a real receiver
service.

Needs ALERTROSTER_RECEIVERD pointing at an alertroster-receiverd binary;
skips (exit 0, says so) without one. Everything runs in a temp dir on a
private port with a private token file, and an `omarchy-shell` stub on PATH
proves the no-service fallback lands in the shell.
"""

import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(os.path.dirname(HERE), "bin")
RECEIVERD = os.environ.get("ALERTROSTER_RECEIVERD") or shutil.which("alertroster-receiverd")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Bridge:
    def __init__(self, token_file, port):
        self.proc = subprocess.Popen(
            [os.path.join(BIN, "alertroster-surface"), "--token-file", token_file, "--port", str(port), "--no-launch"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.raw = b""
        self.out_fd = self.proc.stdout.fileno()

    def send(self, frame):
        self.proc.stdin.write(json.dumps(frame) + "\n")
        self.proc.stdin.flush()

    def next_frame(self, timeout=10.0):
        # Raw reads with our own line buffer: a buffered readline() would
        # swallow the second of two lines that arrive together, and select()
        # on the fd would then never fire for it.
        deadline = time.monotonic() + timeout
        while True:
            if b"\n" in self.raw:
                line, _, self.raw = self.raw.partition(b"\n")
                return json.loads(line.decode("utf-8"))
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([self.out_fd], [], [], remaining)
            if not ready:
                break
            chunk = os.read(self.out_fd, 65536)
            if not chunk:
                break
            self.raw += chunk
        raise AssertionError("no frame from the bridge within %.0fs (stderr: %s)" % (timeout, self.stderr_tail()))

    def expect(self, event, timeout=10.0, **fields):
        """Read frames until one matches `event` and every given field."""
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            frame = self.next_frame(max(0.1, deadline - time.monotonic()))
            seen.append(frame)
            if frame.get("event") == event and all(frame.get(k) == v for k, v in fields.items()):
                return frame
        raise AssertionError("expected %s %s, saw %s" % (event, fields, [f.get("event") + ":" + str(f.get("state", "")) for f in seen]))

    def stderr_tail(self):
        try:
            os.set_blocking(self.proc.stderr.fileno(), False)
            return (self.proc.stderr.read() or "")[-500:]
        except Exception:
            return ""

    def close(self):
        if self.proc.stdin:
            self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return -9


def start_receiverd(tmp, port, token_file):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=tmp, XDG_DATA_HOME=os.path.join(tmp, "data"),
               XDG_CONFIG_HOME=os.path.join(tmp, "config"))
    proc = subprocess.Popen([RECEIVERD, "--database", os.path.join(tmp, "alerts.sqlite"), "--port", str(port),
                             "--token-file", token_file], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if os.path.exists(token_file):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    return proc
            except OSError:
                pass
        if proc.poll() is not None:
            raise AssertionError("receiverd exited early: " + proc.stderr.read())
        time.sleep(0.1)
    raise AssertionError("receiverd did not come up")


def run_cli(name, *args, env=None):
    proc = subprocess.run([os.path.join(BIN, name), *args], env=env, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def main():
    if not RECEIVERD:
        print("surface_test: skipped — set ALERTROSTER_RECEIVERD to an alertroster-receiverd binary")
        return 0

    tmp = tempfile.mkdtemp(prefix="alertroster-surface-test-")
    port = free_port()
    token_file = os.path.join(tmp, "surface.token")
    stub_dir = os.path.join(tmp, "stub")
    os.makedirs(stub_dir)
    # The shell, as far as the CLI can tell: records the call, answers an id.
    with open(os.path.join(stub_dir, "omarchy-shell"), "w") as stub:
        stub.write('#!/bin/bash\necho "$@" >> "%s/shell-calls"\necho local-1\n' % tmp)
    os.chmod(os.path.join(stub_dir, "omarchy-shell"), 0o755)
    cli_env = dict(os.environ, ALERTROSTER_SURFACE_TOKEN=token_file, ALERTROSTER_RECEIVER_PORT=str(port),
                   XDG_CONFIG_HOME=os.path.join(tmp, "config"), XDG_STATE_HOME=os.path.join(tmp, "state"),
                   PATH=stub_dir + os.pathsep + os.environ.get("PATH", ""))

    failures = []
    receiverd = None
    bridge = None

    def check(label, condition, detail=""):
        print(("  ok   " if condition else "  FAIL ") + label + (("  " + str(detail)) if detail and not condition else ""))
        if not condition:
            failures.append(label)

    try:
        print("no service:")
        bridge = Bridge(token_file, port)
        frame = bridge.expect("link", state="absent")
        check("bridge reports absent without a token file", frame["state"] == "absent")
        rc, out, err = run_cli("alertroster-local", "GET", "/v1/status", env=cli_env)
        check("alertroster-local exits 3 with no token", rc == 3, (rc, out, err))
        rc, out, err = run_cli("alertroster-page", "Shell fallback", env=cli_env)
        check("alertroster-page falls back to the shell", rc == 0 and out == "local-1", (rc, out, err))
        with open(os.path.join(tmp, "shell-calls")) as calls:
            check("the shell got the page", "page Shell fallback high cli" in calls.read())
        bridge.close()

        print("service up:")
        receiverd = start_receiverd(tmp, port, token_file)
        bridge = Bridge(token_file, port)
        snapshot = bridge.expect("snapshot")
        check("snapshot on join", snapshot.get("alerts") == [] and snapshot.get("principal") == "surface", snapshot)
        # The bridge says live only once the snapshot is in hand; the frame is
        # ordered before the snapshot on stdout so the plugin flips first.
        bridge.close()
        bridge = Bridge(token_file, port)
        first = bridge.next_frame()
        check("link live is emitted before the snapshot", first.get("event") == "link" and first.get("state") == "live", first)
        bridge.expect("snapshot")

        rc, out, err = run_cli("alertroster-local", "GET", "/v1/status", env=cli_env)
        check("alertroster-local reaches the service", rc == 0 and json.loads(out)["principal"] == "surface", (rc, out, err))

        rc, out, err = run_cli("alertroster-page", "--detail", "disk 98%", "Database is down", env=cli_env)
        check("alertroster-page raises on the service", rc == 0 and out.startswith("Paging via the receiver service: la_"), (rc, out, err))
        alert_id = out.rsplit(" ", 1)[-1]
        triggered = bridge.expect("alert.triggered")
        alert = triggered["alert"]
        check("the alert comes down the socket", alert["id"] == alert_id and alert["title"] == "Database is down" and alert["detail"] == "disk 98%", alert)
        check("the service decided emergency", alert.get("emergency") is True and alert.get("status") == "triggered")
        check("the source is this machine's surface", alert["source"]["id"] == "surface_local", alert["source"])

        rc, out2, _ = run_cli("alertroster-page", "--dedup", "k1", "Dedup one", env=cli_env)
        rc2, out3, _ = run_cli("alertroster-page", "--dedup", "k1", "Dedup one again", env=cli_env)
        check("a repeated dedup key returns the same alert", rc == 0 and rc2 == 0 and out2.rsplit(" ", 1)[-1] == out3.rsplit(" ", 1)[-1], (out2, out3))
        dedup_id = out2.rsplit(" ", 1)[-1]
        bridge.expect("alert.triggered")

        bridge.send({"action": "acknowledge", "id": alert_id, "user": "tester"})
        acked = bridge.expect("alert.acknowledged")["alert"]
        check("ack over the socket carries the user", acked["id"] == alert_id and acked["acknowledged_by"]["user"] == "tester", acked.get("acknowledged_by"))
        check("emergency comes down in the same delta", acked.get("emergency") is False and acked["available_actions"] == ["resolved"])

        bridge.send({"action": "acknowledge", "id": alert_id, "user": "tester"})
        err_frame = bridge.expect("error")
        check("a second ack is an invalid_transition error frame", err_frame.get("error") == "invalid_transition" and err_frame.get("id") == alert_id, err_frame)

        bridge.send({"action": "acknowledge", "id": "la_nope", "user": "tester"})
        err_frame = bridge.expect("error")
        check("unknown id is not_found", err_frame.get("error") == "not_found", err_frame)

        bridge.send({"action": "resolve", "id": alert_id})
        resolved = bridge.expect("alert.resolved")["alert"]
        check("resolve over the socket", resolved["status"] == "resolved" and resolved["available_actions"] == [])

        rc, out, err = run_cli("alertroster-local", "POST", "/v1/alerts/%s/acknowledge" % dedup_id, '{"user":"cli"}', env=cli_env)
        check("ack over HTTP for shell scripts", rc == 0 and json.loads(out)["alert"]["acknowledged_by"]["user"] == "cli", (rc, out, err))
        bridge.expect("alert.acknowledged")

        print("heartbeat:")
        rc, out, err = run_cli("alertroster-heartbeat", "expect", "backup", "1s", env=cli_env)
        check("heartbeat expect", rc == 0, (rc, out, err))
        time.sleep(1.5)
        rc, out, err = run_cli("alertroster-heartbeat", "check", env=cli_env)
        check("heartbeat check runs", rc == 0, (rc, out, err))
        beat = bridge.expect("alert.triggered")["alert"]
        check("a lapsed heartbeat is an alert on the service", beat["title"].startswith("No heartbeat from backup") and beat["dedup_key"] == "heartbeat:backup", beat)
        rc, out, err = run_cli("alertroster-heartbeat", "check", env=cli_env)
        check("check pages once per lapse", rc == 0)
        rc, out, err = run_cli("alertroster-local", "GET", "/v1/alerts", env=cli_env)
        open_titles = [a["title"] for a in json.loads(out)["alerts"]]
        check("only one heartbeat alert open", sum(1 for t in open_titles if t.startswith("No heartbeat")) == 1, open_titles)

        print("service restarts:")
        receiverd.terminate()
        receiverd.wait(timeout=10)
        down = bridge.expect("link", state="down", timeout=12)
        check("link down after the service stops", down["state"] == "down", down)
        receiverd = start_receiverd(tmp, port, token_file)
        live = bridge.expect("link", state="live", timeout=15)
        check("re-attached with the new token", live["state"] == "live")
        snapshot = bridge.expect("snapshot")
        check("the snapshot after restart still holds the open alerts", any(a["id"] == dedup_id for a in snapshot["alerts"]), [a["id"] for a in snapshot["alerts"]])

        print("service gone for good:")
        receiverd.terminate()
        receiverd.wait(timeout=10)
        receiverd = None
        bridge.expect("link", state="down", timeout=12)
        os.remove(token_file)
        # Without a token file and having been live, the bridge holds `down`
        # for a while and then declares the service absent.
        frame = bridge.expect("link", state="absent", timeout=90)
        check("absent once the service has stayed gone", frame["state"] == "absent", frame)
        bridge.send({"action": "acknowledge", "id": dedup_id, "user": "tester"})
        err_frame = bridge.expect("error")
        check("actions while down are link_down errors", err_frame.get("error") == "link_down", err_frame)
        code = bridge.close()
        check("bridge exits 0 when stdin closes", code == 0, code)
        bridge = None
    finally:
        if bridge is not None:
            bridge.proc.kill()
        if receiverd is not None:
            receiverd.terminate()
            try:
                receiverd.wait(timeout=5)
            except subprocess.TimeoutExpired:
                receiverd.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("\n%d failed: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("\nsurface_test: all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
