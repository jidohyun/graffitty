# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Check macOS sleep assertions for private Godot, server, and Chromium processes.

Build gft and the CEF capture changes, then run:

    uv run tests/platform/macos/macos_sleep_e2e.py --component all

Set GRAFFITTY_CHROMIUM_HOST to try a candidate host with the existing installation.

The native window guard keeps test windows from taking over the desktop.
The test leaves the audio driver, lock state, sleep state, and power settings alone.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from websocket import WebSocketTimeoutException

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_background import prepare_background, background_failures
from e2e_server import PrivateServer
from headless_remote_e2e import Client
from private_session_e2e import PrivateClient

BLOCKER = re.compile(r"\b(?:PreventSystemSleep|PreventUserIdleSystemSleep|"
                     r"PreventUserIdleDisplaySleep|NoDisplaySleepAssertion|"
                     r"InternalPreventDisplaySleep)\b")


def descendants(roots):
    owned = set(roots)
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True, timeout=15)
    parents = [tuple(map(int, row.split())) for row in rows.splitlines()]
    while True:
        found = {pid for pid, parent in parents if parent in owned} - owned
        if not found:
            return owned
        owned.update(found)


def sleep_blockers(roots):
    owned = descendants(roots)
    listing = subprocess.check_output(["pmset", "-g", "assertions"], text=True, timeout=15)
    failures = []
    # CoreAudio holds assertions in coreaudiod on behalf of the audio client.
    # Checking only assertions directly owned by the frontend misses that bug.
    for record in re.split(r"(?=^\s*pid \d+\()", listing, flags=re.M):
        owner = re.match(r"\s*pid (\d+)\(", record)
        client = re.search(r"Created for PID:\s*(\d+)", record)
        attributed = {int(m.group(1)) for m in (owner, client) if m}
        if owned & attributed and BLOCKER.search(record):
            failures.append(record.strip())
    return failures


def assert_sleep_allowed(roots, phase):
    for _ in range(6):
        failures = sleep_blockers(roots)
        assert not failures, f"{phase} prevents sleep:\n" + "\n".join(failures)
        time.sleep(.25)
    print(f"PASS {phase}: no display/system sleep assertions", flush=True)


@contextmanager
def child(command, env, log):
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT)
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def godot_check(root, env, binary):
    probe = root / "probe.gd"
    probe.write_text('''extends SceneTree
func _initialize() -> void:
    print("SLEEP_PROBE " + JSON.stringify({
        "audio_driver": AudioServer.get_driver_name(),
        "keep_screen_on": DisplayServer.screen_is_kept_on(),
        "display_server": DisplayServer.get_name(),
        "native_dictation": DictationAudio.has_native_capture()
    }))
''')
    env = env.copy()
    evidence = root / "native"
    flags = prepare_background(env, evidence)
    # This regression must exercise project.godot's audio policy, not the
    # ordinary visual-test harness's forced Dummy driver.
    index = flags.index("--audio-driver")
    del flags[index:index + 2]
    log = root / "godot.log"
    with child([binary, *flags, "--path", str(ROOT / "frontends/godot/project"),
                "--script", str(probe)], env, log) as process:
        deadline = time.monotonic() + 30
        while True:
            text = log.read_text()
            assert process.poll() is None, text
            match = re.search(r"^SLEEP_PROBE (.+)$", text, re.M)
            if match:
                assert json.loads(match[1]) == {
                    "audio_driver": "Dummy", "keep_screen_on": False,
                    "display_server": "macOS", "native_dictation": True,
                }, text
                break
            assert time.monotonic() < deadline, text
            time.sleep(.1)
        assert_sleep_allowed([process.pid], "Godot desktop")
        failures = background_failures(evidence, process.pid)
        assert not failures, failures


def server_check(root, env, chromium):
    with PrivateServer(env, root, "/bin/sh", startup_timeout=120) as server:
        descriptor = json.loads(server.descriptor.read_text())
        local = PrivateClient(descriptor["local"], "sleep-policy", timeout=30)
        remote = None
        try:
            pane = local.topology["panes"][0]["id"]
            reply = local.action("text", pane, text="printf 'sleep-policy-terminal\\n'\n")
            assert reply["type"] == "ack", reply
            assert_sleep_allowed([server.process.pid], "standalone session server")
            if not chromium:
                return
            shared = local.action("remote_access", enabled=True, address="127.0.0.1:0")
            assert shared["type"] == "ack", shared
            remote = Client(dict(shared["result"], local=descriptor["local"]),
                            workspace="sleep-policy", chromium_video=["hevc", "h264"])
            remote.ws.settimeout(.1)
            sequence = 0

            def pump():
                try:
                    remote.receive()
                except WebSocketTimeoutException:
                    pass

            def call(method, **params):
                nonlocal sequence
                sequence += 1
                request = sequence
                remote.action("rpc", pane, request=request, method=method, params=params)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    pump()
                    reply = next((m for m in remote.messages if m.get("request") == request), None)
                    if reply:
                        remote.messages.remove(reply)
                        assert reply["type"] == "ack", reply
                        return reply["result"]
                raise AssertionError(f"{method} timed out")

            handle = call("chromium.create", url="about:blank")["chromium"]
            browser_id = int(handle[1:])
            remote.action("subscribe", sessions=[browser_id])
            deadline = time.monotonic() + 45
            while browser_id not in remote.frames:
                assert time.monotonic() < deadline, "Chromium must deliver real frames"
                pump()
            ticket = call("chromium.command", chromium=handle, action="cdp", args={
                "method": "Runtime.evaluate", "params": {"expression":
                    "let n=0;function frame(){document.body.style.background="
                    "n++%2?'cyan':'magenta';requestAnimationFrame(frame)}frame();true",
                    "returnByValue": True},
            })["ticket"]
            deadline = time.monotonic() + 20
            while True:
                result = call("chromium.result", chromium=handle, ticket=ticket)
                if result is not None:
                    assert result.get("result", {}).get("result", {}).get("value") is True, result
                    break
                assert time.monotonic() < deadline, "Animation setup timed out"
                pump()
            assert len(descendants([server.process.pid])) > 2, "Chromium host must be running"
            assert_sleep_allowed([server.process.pid], "server with remote Chromium capture")
            previous = remote.frames[browser_id]["frame"]
            deadline = time.monotonic() + 10
            while remote.frames[browser_id]["frame"] == previous:
                assert time.monotonic() < deadline, "Capture stalled with sleep permitted"
                pump()
            print("PASS Chromium keeps delivering frames without a sleep blocker", flush=True)
            remote.ws.close()
            remote = None
            local.socket.close()
            local = None
            time.sleep(1)
            assert_sleep_allowed([server.process.pid], "detached server and Chromium")
        finally:
            if remote:
                remote.ws.close()
            if local:
                local.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=["godot", "server", "chromium", "all"], default="all")
    parser.add_argument("--godot", default=os.environ.get("GODOT") or shutil.which("godot"))
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This test reads macOS IOKit assertions through pmset")
    with tempfile.TemporaryDirectory(prefix="gft-sleep-") as directory:
        root = Path(directory)
        env = {k: v for k, v in os.environ.items()
               if k == "GRAFFITTY_CHROMIUM_HOST" or not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        try:
            if args.component in ("godot", "all"):
                assert args.godot, "Godot is required"
                godot_check(root, env, args.godot)
            if args.component in ("server", "chromium", "all"):
                server_check(root, env, args.component != "server")
        except Exception:
            for log in (root / "godot.log", root / "session-owner/server.log"):
                if log.exists():
                    print(f"{log.name}:\n{log.read_text(errors='replace')[-12000:]}", file=sys.stderr)
            raise
    print("MACOS_SLEEP_POLICY_PASS", flush=True)


if __name__ == "__main__":
    main()
