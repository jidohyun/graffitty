"""Runs INSIDE a test PTY, exercising inherited context, CLI and MCP."""

import json
import os
import socket
import subprocess
import sys
import traceback
from pathlib import Path

cli = os.environ["GRAFFITTY_BIN"]
result_path, foreign = sys.argv[1:3]
checks = []


def run(*args, success=True):
    process = subprocess.run(
        [cli, *args], capture_output=True, text=True, timeout=65
    )
    response = json.loads(process.stdout)
    assert (process.returncode == 0) == success, response
    return response


def rpc(method, params=None, success=True):
    return run("rpc", method, "--params", json.dumps(params or {}), success=success)


try:
    identity = run("identify")["result"]
    assert str(identity["tab_id"]) == os.environ["GRAFFITTY_TAB_ID"]
    checks.append("PTY inherits its own scoped identity")
    denied = rpc("chromium.snapshot", {"chromium": foreign}, success=False)
    assert denied["error"]["code"] == "forbidden", denied
    checks.append("cross-tab chromium access denied")
    denied = rpc("chromium.create", {"tab_id": 999999}, success=False)
    assert denied["error"]["code"] == "forbidden"
    with socket.socket(socket.AF_UNIX) as client:
        # The owner accepts the existing one-request JSON protocol on its private
        # IPC socket; the endpoint URI is not itself a filesystem path.
        client.settimeout(10)
        client.connect(os.environ["GRAFFITTY_SOCKET"].removeprefix("ipc://"))
        client.sendall(b'{"id":1,"method":"identify","token":"wrong"}\n')
        response = json.loads(client.makefile().readline())
        assert response["error"]["code"] == "unauthorized"
    checks.append("invalid capability denied")
    created = run("chromium", "create")["result"]
    chromium = created["chromium"]
    assert created.get("tab_id") == identity["tab_id"], created

    def chromium_call(verb, **params):
        return rpc("chromium." + verb, {"chromium": chromium, **params})

    fixture = "document.body.innerHTML='<label>Name<input id=name></label><button id=go>Go</button><p id=result></p>';document.querySelector('#go').onclick=()=>{document.querySelector('#result').textContent=document.querySelector('#name').value;window.clicked=true};window.retained=123"
    chromium_call("eval", expression=fixture)
    snapshot = chromium_call("snapshot")["result"]
    field = next(e["ref"] for e in snapshot["elements"] if e["tag"] == "input")
    button = next(e["ref"] for e in snapshot["elements"] if e["tag"] == "button")
    chromium_call("fill", ref=field, text="agent chromium test")
    chromium_call("click", ref=button)
    chromium_call("wait", text="agent chromium test")
    assert chromium_call("eval", expression="window.clicked")["result"] is True
    assert (
        chromium_call(
            "eval", expression="document.querySelector('#result').textContent"
        )["result"]
        == "agent chromium test"
    )
    checks.append("snapshot refs, fill, native CDP click, wait and eval work")
    chromium_call("snapshot")
    stale = rpc("chromium.click", {"chromium": chromium, "ref": button}, success=False)
    assert stale["error"]["code"] == "stale_ref"
    checks.append("stale snapshot references rejected")
    native = chromium_call("present", mode="native")
    assert native["result"]["nativeVisible"] is True, native
    embedded = chromium_call("present", mode="embedded")
    assert embedded["result"]["nativeVisible"] is False, embedded
    assert chromium_call("eval", expression="window.retained")["result"] == 123
    checks.append("presentation retains live JS state")
    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-06-18"},
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "workspace_chromium",
                "arguments": {"method": "identify"},
            },
        },
    ]
    mcp = subprocess.run(
        [cli, "mcp"],
        input="".join(json.dumps(m) + "\n" for m in messages),
        text=True,
        capture_output=True,
        timeout=30,
    )
    replies = [json.loads(line) for line in mcp.stdout.splitlines()]
    assert (
        len(replies) == 3
        and replies[1]["result"]["tools"][0]["name"] == "workspace_chromium"
    ), replies
    assert (
        json.loads(replies[2]["result"]["content"][0]["text"])["result"]["tab_id"]
        == identity["tab_id"]
    )
    checks.append("stdio MCP uses same workspace capability")
    result = {
        "ok": True,
        "checks": checks,
        "chromium": chromium,
        "tab_id": identity["tab_id"],
    }
except Exception:
    result = {"ok": False, "checks": checks, "error": traceback.format_exc()}
Path(result_path).write_text(json.dumps(result))
print("AGENT_CLIENT_PASS" if result["ok"] else "AGENT_CLIENT_FAIL", flush=True)
