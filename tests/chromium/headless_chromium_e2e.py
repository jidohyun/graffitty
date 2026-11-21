# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real headless Chromium: server automation, preview, detach and explicit close."""

import json
import os
import subprocess
import tempfile
import time
import shutil
from pathlib import Path

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


def main():
    with tempfile.TemporaryDirectory(prefix="gr-chromium-") as directory:
        path = Path(directory) / "server.json"
        with (Path(directory) / "server.log").open("w") as log:
            server = subprocess.Popen(
                [
                    BINARY,
                    "server", "--listen",
                    "127.0.0.1:0",
                    "--connection",
                    path,
                    "--auth-file",
                    Path(directory) / "auth.json",
                    "--shell",
                    "/bin/sh",
                ],
                stdout=log,
                stderr=log,
                env=dict(os.environ, DISPLAY="", WAYLAND_DISPLAY=""),
            )
        client = None
        try:
            for _ in range(100):
                if path.is_file():
                    break
                assert server.poll() is None
                time.sleep(0.05)
            descriptor = json.loads(path.read_text())
            client = Client(descriptor, chromium_video=["h264", "hevc", "av1"])
            pane = client.topology["panes"][0]["id"]
            request = 0

            def rpc(method, **params):
                nonlocal request
                request += 1
                client.action(
                    "rpc", pane, request=request, method=method, params=params
                )
                client.until(
                    lambda: any(m.get("request") == request for m in client.messages)
                )
                response = next(
                    m for m in client.messages if m.get("request") == request
                )
                assert response["type"] == "ack", response
                return response["result"]

            chromium = rpc("chromium.create", url="about:blank")["chromium"]
            chromium_id = int(chromium[1:])
            client.until(
                lambda: (
                    (client.topology.get("chromiums") or [{}])[0]
                    .get("state", {})
                    .get("chromiumId", -1)
                    > 0
                )
            )
            client.action("subscribe", sessions=[pane, chromium_id])
            client.until(
                lambda: client.frames.get(chromium_id, {}).get("type") == "chromium"
            )
            frame = client.frames[chromium_id]
            assert frame["format"] in ("h264", "hevc", "av1"), frame
            assert frame["key"] and frame["width"] > 0 and frame["height"] > 0, frame
            assert len(client.payloads[chromium_id]) > 100

            def evaluate(expression):
                ticket = rpc(
                    "chromium.command",
                    chromium=chromium,
                    action="cdp",
                    args={
                        "method": "Runtime.evaluate",
                        "params": {"expression": expression, "returnByValue": True},
                    },
                )["ticket"]
                for _ in range(100):
                    result = rpc("chromium.result", chromium=chromium, ticket=ticket)
                    if result is not None:
                        assert "error" not in result, result
                        return result["result"]["result"]["value"]
                    time.sleep(0.025)
                raise AssertionError("Chromium command timed out")

            assert (
                evaluate(
                    "window.fixture=42; document.body.innerHTML='<h1>한글</h1>'; fixture"
                )
                == 42
            )
            # A real Godot client sends letterboxed pointer coordinates, key events,
            # drags and scrolling through RemoteChromiumSession, not DOM automation.
            root = Path(__file__).resolve().parents[2]
            try:
                gd = subprocess.run([
                    os.environ.get("GODOT") or shutil.which("godot"), "--headless", "--path", str(root / "frontends/godot/project"), "--script",
                    "tests/remote_chromium_input_e2e.gd", "--", str(path), str(pane), str(chromium_id),
                ], capture_output=True, text=True, timeout=45, env={**os.environ, **{
                    "XDG_" + kind + "_HOME": str(Path(directory) / kind.lower())
                    for kind in ["CONFIG", "STATE", "DATA", "CACHE"]
                }})
            except subprocess.TimeoutExpired as error:
                print(error.stdout, error.stderr, flush=True)
                raise
            assert gd.returncode == 0 and "REMOTE_CHROMIUM_INPUT_PASS" in gd.stdout, gd.stdout + gd.stderr
            assert "SCRIPT ERROR" not in gd.stderr, gd.stderr
            print(gd.stdout, end="")
            if gd.stderr:
                print(gd.stderr, end="")

            # Pending automation must keep servicing input and video frames.
            ticket = rpc("chromium.command", chromium=chromium, action="cdp", args={
                "method": "Runtime.evaluate", "params": {
                    "expression": "new Promise(resolve => { document.addEventListener('keydown', () => resolve('input-unblocked'), {once:true}); })",
                    "awaitPromise": True, "returnByValue": True,
                },
            })["ticket"]
            time.sleep(.1)
            rpc("chromium.input", chromium=chromium, event={"method": "Input.dispatchKeyEvent", "params": {"type": "keyDown", "key": "x", "text": "x", "windowsVirtualKeyCode": 88}})
            started = time.monotonic()
            while True:
                result = rpc("chromium.result", chromium=chromium, ticket=ticket)
                if result is not None:
                    assert result["result"]["result"]["value"] == "input-unblocked", result
                    break
                assert time.monotonic() - started < 3, "Input blocked behind pending automation"
                time.sleep(.01)
            print("PASS Godot pointer/keyboard/scroll input and input during pending automation")
            client.ws.close()
            client = Client(descriptor, chromium_video=["h264", "hevc", "av1"])
            assert evaluate("window.fixture") == 42
            rpc("chromium.close", chromium=chromium)
            client.until(lambda: client.topology.get("chromiums") == [])
            client.text(pane, "printf 'CHROMIUM_%s_OK\\n' CLOSED\r")
            client.has_output(pane, "CHROMIUM_CLOSED_OK")
            print(
                "PASS headless Chromium preview, automation, Unicode DOM, detach persistence, explicit close and unaffected PTY"
            )
        finally:
            if client is not None:
                client.ws.close()
            server.terminate()
            server.wait(timeout=15)


if __name__ == "__main__":
    main()
