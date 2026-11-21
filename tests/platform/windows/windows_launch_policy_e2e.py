"""Observe Windows launch defaults and history budgets through private real PTYs.

This server-only evidence does not certify GUI policy controls or image rendering.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from test_session_transfer import Peer


def history(peer, pane):
    peer.send(dict(type="history", session=pane))
    return peer.until(lambda m: m.get("type") == "history" and m.get("session") == pane)["text"]


def wait_history(peer, pane, marker):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        text = history(peer, pane)
        if marker in text:
            return text
        time.sleep(.05)
    raise AssertionError(f"Shell {pane} did not print {marker}: {text[-2000:]}")


def run(directory, shell, report):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    config = directory / "config/graffitty/server.toml"
    config.parent.mkdir(parents=True)
    literal = "한글 Ω $(not_a_command) `literal`"
    config.write_text('[terminal]\nshell = ' + json.dumps([shell, "-NoLogo", "-NoProfile"]) +
                      '\nshell_integration = false\nlogin_shell = false\n'
                      '[terminal.environment]\nGFT_POLICY_LITERAL = ' + json.dumps(literal, ensure_ascii=False) +
                      '\n[terminal.limits]\nscrollback_bytes = 64\n', encoding="utf-8")
    config_hash = hashlib.sha256(config.read_bytes()).hexdigest()
    with PrivateServer(env, directory, None) as owner:
        report["binary"] = str(owner.binary)
        report["sha256"] = hashlib.sha256(owner.binary.read_bytes()).hexdigest()
        local = json.loads(owner.descriptor.read_text())["local"]
        peer = Peer(local, "policy")
        try:
            original = peer.topology["panes"][0]
            assert original["limits"]["scrollback_bytes"] == 64
            cwd = directory / "한글 working directory"
            cwd.mkdir()
            panes = [original]
            for budget in (16 * 1024 * 1024, 0):
                reply = peer.action("create", original["id"], kind="pane",
                                    spawn={"scrollback_bytes": budget, "cwd": str(cwd)})
                assert reply["type"] == "ack", reply
                panes.append(next(p for p in peer.sync()["panes"] if p["id"] == reply["created"]))
            assert len({p["pid"] for p in panes}) == 3
            report["panes"] = panes
            for index, pane in enumerate(panes):
                receipt = directory / f"shell-{index}.json"
                quoted = str(receipt).replace("'", "''")
                command = ("@{pid=$PID;cwd=(Get-Location).Path;literal=$env:GFT_POLICY_LITERAL;"
                           "version=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress | "
                           f"Set-Content -LiteralPath '{quoted}' -Encoding UTF8\r")
                assert peer.action("text", pane["id"], text=command)["type"] == "ack"
                deadline = time.monotonic() + 30
                while not receipt.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                observed = json.loads(receipt.read_text(encoding="utf-8-sig"))
                assert observed["pid"] == pane["pid"], observed
                assert observed["literal"] == literal, observed
                if index:
                    assert Path(observed["cwd"]) == cwd, observed
                report.setdefault("shells", []).append(observed)
                token = uuid.uuid4().hex
                # Markers are assembled by the shell, so echoed command text
                # cannot satisfy either the first-line or completion assertion.
                command = f"$t='{token}'; 0..4999 | ForEach-Object {{ [Console]::WriteLine($t + ':' + $_) }}\r"
                assert peer.action("text", pane["id"], text=command)["type"] == "ack"
                text = wait_history(peer, pane["id"], token + ":4999")
                (directory / f"history-{index}.txt").write_text(text, encoding="utf-8")
                first = token + ":0" in text
                assert first == (index == 1), (index, "Unexpected retention", len(text))
                report.setdefault("history", []).append({"budget": pane["limits"]["scrollback_bytes"],
                    "first_retained": first, "last_retained": True, "characters": len(text)})
            before = {p["id"]: (p["pid"], p["limits"]) for p in peer.sync()["panes"]}
            for spawn in ({"shell": str(directory / "missing.exe")},
                          {"cwd": str(directory / "missing-directory")},
                          {"scrollback_bytes": 134217729},
                          {"env": {"GRAFFITTY_SESSION_TOKEN": "invalid"}}):
                reply = peer.action("create", original["id"], kind="pane", spawn=spawn)
                assert reply["type"] == "error", reply
                assert {p["id"]: (p["pid"], p["limits"]) for p in peer.sync()["panes"]} == before
                report.setdefault("rejected", []).append({"spawn": spawn, "reply": reply})
            retained = history(peer, panes[1]["id"])
            peer.socket.close()
            peer = Peer(local, "policy")
            assert {p["id"]: (p["pid"], p["limits"]) for p in peer.topology["panes"]} == before
            assert history(peer, panes[1]["id"]) == retained
            for pane in panes:
                # Keep the completed output below the smallest pane width;
                # history preserves physical row breaks after a three-way split.
                marker = uuid.uuid4().hex[:16]
                peer.action("text", pane["id"], text=f"Write-Output ('REATTACH=' + '{marker}')\r")
                observed = wait_history(peer, pane["id"], "REATTACH=" + marker)
                (directory / f"reattached-{pane['id']}.txt").write_text(observed, encoding="utf-8")
            report["reattached_same_pids_and_history"] = True
            assert hashlib.sha256(config.read_bytes()).hexdigest() == config_hash
            report["config_sha256"] = config_hash
        finally:
            peer.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--shell", choices=["powershell.exe", "pwsh.exe"], required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Requires native Windows")
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    report = {"shell": args.shell, "status": "fail", "scope": "server PTYs; no GUI or image acceptance"}
    try:
        run(directory, args.shell, report)
        report["status"] = "pass"
    except Exception as error:
        report["error"] = repr(error)
        raise
    finally:
        (directory / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{report['status'].upper()}: {args.shell}; evidence: {directory / 'report.json'}")


if __name__ == "__main__":
    main()
