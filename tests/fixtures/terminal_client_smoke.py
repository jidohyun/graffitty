#!/usr/bin/env python3
"""Launched by the GPU smoke test with its own workspace capability."""

import json
import os
import subprocess
import sys
from pathlib import Path


def command(*args, env=None):
    result = subprocess.run(
        [os.environ["GRAFFITTY_BIN"], *args],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )
    value = json.loads(result.stdout)
    assert (result.returncode == 0) == ("error" not in value), value
    return value


def main():
    target = Path(sys.argv[1])
    try:
        identity = command("identify")["result"]
        foreign = command(
            "rpc",
            "terminal.type",
            "--params",
            json.dumps({"text": "bad", "tab_id": identity["tab_id"] + 1000}),
        )
        assert foreign["error"]["code"] == "forbidden", foreign
        denied = command(
            "terminal",
            "type",
            "--text",
            "bad",
            env=dict(os.environ, GRAFFITTY_TOKEN="invalid-test-token"),
        )
        assert denied["error"]["code"] == "unauthorized", denied
        for key in ["Ctrl+e", "Ctrl+u"]:
            response = command("terminal", "send-key", key)
            assert response.get("result", {}).get("keys_sent") == 1, response
        text = "printf '%s%s\\n' 'TERMINAL_' 'CLIENT_OK'"
        assert command("terminal", "type", "--text", text, "--interval-ms", "5")[
            "result"
        ]["keys_sent"] == len(text)
        assert (
            command("terminal", "send-key", "Enter")["result"]["keys_sent"] == 1
        )
        target.write_text(json.dumps({"ok": True}))
    except Exception as exc:
        target.write_text(json.dumps({"ok": False, "error": str(exc)}))
        raise


if __name__ == "__main__":
    main()
