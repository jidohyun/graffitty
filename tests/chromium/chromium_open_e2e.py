#!/usr/bin/env python3
"""Exercise shared local-file opening against a real isolated server and Chromium."""
import json
import os
from pathlib import Path
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from local_media_e2e import LocalClient, PrivateServer


def main():
    with tempfile.TemporaryDirectory(prefix="gft-chromium-open-") as temporary:
        root = Path(temporary)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        path = root / "preview 한 # %.html"
        path.write_text('<!doctype html><title>Local preview</title><h1>Preview</h1>')
        with PrivateServer(env, root, "/bin/sh") as server:
            client = LocalClient(json.loads(server.descriptor.read_text()))
            try:
                source = int(client.topology["panes"][0]["id"])
                def request(method, params):
                    client.sequence += 1
                    seq = client.sequence
                    client.send(dict(type="rpc", session=source, request=seq, method=method, params=params))
                    client.until(lambda: any(m.get("request") == seq for m in client.messages))
                    return next(m for m in client.messages if m.get("request") == seq)
                def call(method, **params):
                    reply = request(method, params)
                    assert reply["type"] == "ack", reply
                    return reply["result"]
                def state(chromium):
                    ticket = call("chromium.command", chromium=chromium, action="chrome-state")["ticket"]
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        result = call("chromium.result", chromium=chromium, ticket=ticket)
                        if result is not None:
                            assert "error" not in result, result
                            return result["result"]
                        time.sleep(.05)
                    raise AssertionError("Chromium did not become ready")
                first = call("chromium.open", path=str(path))
                assert first["created"]
                chromium = first["chromium"]
                initial = state(chromium)
                assert len(initial["tabs"]) == 1
                second = call("chromium.open", path=str(path))
                assert second["chromium"] == chromium and not second["created"]
                assert len(state(chromium)["tabs"]) == 2
                # A terminal's chromium.open places the chromium to its right.
                third = call("chromium.open", path=str(path), chromium="main:1.2")
                assert third["chromium"] == chromium and not third["created"]
                assert len(state(":1.2")["tabs"]) == 3
                fresh = call("chromium.open", path=str(path), new=True)
                assert fresh["created"] and fresh["chromium"] != chromium
                assert len(state(fresh["chromium"])["tabs"]) == 1
                template = root / "template"
                (template / "Default").mkdir(parents=True)
                (template / "Default" / "marker").write_text("template")
                cloned = call("chromium.open", path=str(path), new=True, profile_template=str(template))
                cloned_state = state(cloned["chromium"])
                profile = Path(cloned_state["profile"])
                assert cloned_state["temporaryProfile"] and profile != template, cloned_state
                assert (profile / "Default" / "marker").read_text() == "template"
                assert not (template / "SingletonLock").exists()
                for params in [dict(path=str(path), chromium=f"%{source}"),
                               dict(path=str(path), chromium=chromium, profile_template=str(template)),
                               dict(path=str(path), new=True, profile="/a", profile_template=str(template)),
                               dict(path=str(path), chromium="other:1.2"),
                               dict(path=str(path), chromium=chromium, new=True),
                               dict(path=str(root)), dict(path=str(root / "missing"))]:
                    reply = request("chromium.open", params)
                    assert reply["type"] != "ack", reply
                print("PASS local file URL encoding, reuse, session targets, forced creation, profile templates, and invalid targets")
            finally:
                client.close()


if __name__ == "__main__":
    main()
