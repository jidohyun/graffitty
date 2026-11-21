#!/usr/bin/env python3
"""Verify new panes and tabs inherit cwd, launch cwd, then home via real PTYs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from local_media_e2e import LocalClient, PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    os.environ["GRAFFITTY_TEST_SERVER"] = str(args.server.resolve())
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GRAFFITTY_",))
           and key not in ("CODEX_THREAD_ID", "CODEX_SESSION_ID")}
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    launch = directory / "original launch cwd"
    current = launch / "pane cwd"
    current.mkdir(parents=True)
    checks = []
    report = {"status": "FAIL", "server_sha256": hashlib.sha256(args.server.read_bytes()).hexdigest(), "checks": checks}
    try:
        with PrivateServer(env, directory, "/bin/sh") as owner:
            client = LocalClient(json.loads(owner.descriptor.read_text()))
            try:
                def request(action, session=-1, **values):
                    client.sequence += 1
                    sequence = client.sequence
                    client.send(dict(type=action, session=session, request=sequence, **values))
                    client.until(lambda: any(m.get("request") == sequence for m in client.messages))
                    reply = next(m for m in client.messages if m.get("request") == sequence)
                    assert reply["type"] == "ack", reply
                    return reply

                def pwd(pane, expected, name, prefix=""):
                    output = directory / f"pwd-{len(checks)}.txt"
                    request("text", pane, text=f"{prefix}pwd -P > {shlex.quote(str(output))}\n")
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if output.exists() and output.read_text().strip():
                            break
                        time.sleep(.01)
                    actual = output.read_text().strip() if output.exists() else ""
                    checks.append(dict(name=name, expected=str(expected.resolve()), actual=actual))
                    assert actual == str(expected.resolve()), checks[-1]

                spawn = {"shell": "/bin/sh", "login": False}
                source = request("create", kind="tab", spawn=dict(spawn, cwd=str(launch)))["created"]
                pwd(source, launch, "explicit GUI launch directory")
                pwd(source, current, "source pane changed directory", prefix=f"cd {shlex.quote(str(current))}; ")
                descendants = []
                for kind in ("pane", "tab"):
                    child = request("create", source, kind=kind, spawn=spawn)["created"]
                    descendants.append(child)
                    pwd(child, current, f"new {kind} inherits source cwd")
                current.rmdir()
                for kind, child in zip(("pane", "tab"), descendants):
                    grandchild = request("create", child, kind=kind, spawn=spawn)["created"]
                    pwd(grandchild, launch, f"new {kind} retains original launch fallback through a descendant")
                launch.rmdir()
                home = Path(env.get("HOME") or env["USERPROFILE"])
                for kind, child in zip(("pane", "tab"), descendants):
                    grandchild = request("create", child, kind=kind, spawn=spawn)["created"]
                    pwd(grandchild, home, f"new {kind} falls back to home after both directories disappear")
                report["status"] = "PASS"
            finally:
                client.close()
    finally:
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
