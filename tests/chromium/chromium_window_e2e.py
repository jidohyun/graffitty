#!/usr/bin/env python3
"""Native Chromium tab detach retains a page and creates a same-session pane.

Uses Chromium's own Move tab to new window command, not a replacement page.
Only an isolated private test server and its chromium are touched.
"""
import argparse
from contextlib import nullcontext
import json
import os
import select
import struct
import subprocess
import sys
from pathlib import Path
import tempfile
import time
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support", "tests")]
from local_media_e2e import LocalClient, PrivateServer
from e2e_macos_windows import float_test_windows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--float-test-windows', action='store_true',
                        help='Float only the private Chromium windows in AeroSpace')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[2] / 'frontends/godot/project')
    args = parser.parse_args()
    if args.float_test_windows and sys.platform != 'darwin':
        parser.error('--float-test-windows requires macOS and AeroSpace')
    if args.evidence:
        args.evidence = args.evidence.resolve()
        args.evidence.mkdir(parents=True, exist_ok=False)
    with (nullcontext(args.evidence) if args.evidence else tempfile.TemporaryDirectory(prefix="gft-chromium-windows-")) as temporary:
        root = Path(temporary)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        if os.environ.get("GRAFFITTY_TEST_CHROMIUM_HOST"):
            env["GRAFFITTY_CHROMIUM_HOST"] = os.environ["GRAFFITTY_TEST_CHROMIUM_HOST"]
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        config = root / "config/graffitty/server.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[chromium]\nbackend = "chrome"\n')
        path = root / "page.html"
        path.write_text('<!doctype html><title>Retained page</title><input id="draft"><body style="background:blue">')
        with PrivateServer(env, root, "/bin/sh", startup_timeout=120) as server:
            client = LocalClient(json.loads(server.descriptor.read_text()))
            try:
                source = int(client.topology["panes"][0]["id"])
                def call(method, **params):
                    return client.action("rpc", source, method=method, params=params)
                def command(chromium, action, timeout=20, **args):
                    ticket = call("chromium.command", chromium=chromium, action=action, args=args)["ticket"]
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        result = call("chromium.result", chromium=chromium, ticket=ticket)
                        if result is not None:
                            with (root / 'commands.jsonl').open('a') as journal:
                                journal.write(json.dumps({'at': time.monotonic(), 'chromium': chromium,
                                    'action': action, 'args': args, 'result': result}) + '\n')
                            assert "error" not in result, result
                            return result["result"]
                        time.sleep(.05)
                    raise AssertionError("Chromium command timed out")
                def cdp(chromium, method, **params):
                    return command(chromium, "cdp", method=method, params=params)
                def evaluate(chromium, expression):
                    return cdp(chromium, "Runtime.evaluate", expression=expression, returnByValue=True)["result"]["value"]
                def topology():
                    return next(m for m in reversed(client.messages) if m.get("type") == "topology")
                main = call("chromium.open", path=str(path))["chromium"]
                command(main, "chrome-state", timeout=90)
                call("chromium.open", path=str(path))
                original = command(main, "chrome-state")
                assert len(original["tabs"]) == 2, original
                selected_target = original["primaryTargetId"]
                moved = command(main, "tab-move", chromium_id=original["chromiumId"], index=0)
                # Page ids follow pages: the moved, selected tab keeps its id.
                assert moved["primaryTargetId"] == selected_target and moved["chromiumId"] == original["chromiumId"]
                assert moved["tabs"][0]["id"] == original["chromiumId"]
                assert command(main, "chrome-state")["chromiumId"] == original["chromiumId"]
                original = moved
                deadline = time.monotonic() + 20
                while not evaluate(main, "Boolean(document.querySelector('input'))"):
                    assert time.monotonic() < deadline, "Fixture did not load"
                    time.sleep(.05)
                assert evaluate(main, "window.retained = 'live-js'; document.querySelector('input').value = 'unsaved'; localStorage.shared='same-profile'; true")
                cdp(main, "Graffitty.present", mode="native")
                if args.float_test_windows:
                    isolation = float_test_windows(original['pid'], server.process)
                    (root / 'window-isolation.json').write_text(json.dumps(isolation, indent=2))
                # Native resizing must change the page viewport, independent
                # of stale embedded-pane size requests.
                native = cdp(main, "Browser.getWindowForTarget", targetId=selected_target)
                native_id = native["windowId"]
                cdp(main, "Browser.setWindowBounds", windowId=native_id, bounds={"width": 1100, "height": 850})
                time.sleep(.3)
                large = evaluate(main, "[innerWidth,innerHeight]")
                cdp(main, "Browser.setWindowBounds", windowId=native_id, bounds={"width": 800, "height": 650})
                time.sleep(.3)
                small = evaluate(main, "[innerWidth,innerHeight]")
                assert large[0] > small[0] and large[1] > small[1], (large, small)
                command(main, "resize", width=640, height=400)
                assert cdp(main, "Browser.getWindowBounds", windowId=native_id)["bounds"]["width"] == 800
                assert evaluate(main, "[innerWidth,innerHeight]") == small
                cdp(main, "Graffitty.detachTab")
                client.until(lambda: len(topology().get("chromiums", [])) == 2)
                panes = topology()["chromiums"]
                primary = next(p for p in panes if p["state"].get("mainWindow"))
                secondary = next(p for p in panes if not p["state"].get("mainWindow"))
                child = f'%{secondary["id"]}'
                deadline = time.monotonic() + 15
                while True:
                    detached = command(child, "chrome-state")
                    if detached.get("tabs"): break
                    assert time.monotonic() < deadline, detached
                remaining = command(main, "chrome-state")
                assert detached["nativeVisible"] and remaining["nativeVisible"], (detached, remaining)
                assert detached["visibleWindows"] == 2, detached
                assert len(detached["tabs"]) == len(remaining["tabs"]) == 1, (detached, remaining)
                assert detached["primaryTargetId"] == original["primaryTargetId"]
                assert detached["pid"] == remaining["pid"] == original["pid"]
                assert detached["profile"] == remaining["profile"] == original["profile"]
                assert detached["sessionId"] == remaining["sessionId"]
                assert detached["windowId"] != remaining["windowId"]
                assert secondary["owner"] == primary["id"], panes
                assert primary["owner"] == source, panes
                assert evaluate(child, "[window.retained,document.querySelector('input').value,localStorage.shared]") == ['live-js','unsaved','same-profile']
                assert evaluate(main, "window.retained === undefined")
                if args.float_test_windows:
                    # Detach creates another native window after initial
                    # isolation. A tiler can otherwise resize/re-show that new
                    # window while the test switches it back to embedded mode.
                    isolation = float_test_windows(original['pid'], server.process)
                    (root / 'window-isolation-detached.json').write_text(json.dumps(isolation, indent=2))
                # Different window viewports must produce different GPU frames,
                # even though both capture workers share one Chromium process.
                from conformance.local_gpu_probe import NativeGpu
                native = NativeGpu(root)
                try:
                    peer_pid = struct.unpack("i", client.socket.getsockopt(0, 2, 4))[0]
                    def frame(receiver, predicate):
                        deadline = time.monotonic() + 30
                        last = None
                        while time.monotonic() < deadline:
                            while select.select([client.socket], [], [], 0)[0]: client.receive()
                            value = receiver.poll(peer_pid)
                            if value and predicate(value): return value
                            if value:
                                last = (value.probe, value.width, value.height, value.sample(value.width // 2, value.height // 2))
                                value.close()
                            time.sleep(.01)
                        raise AssertionError(("Window did not deliver its own GPU pixels", last, command(main, "chrome-state"), command(child, "chrome-state")))
                    receivers = []
                    for handle, color, size in [(main, "red", (640, 400)), (child, "blue", (800, 600))]:
                        cdp(handle, "Graffitty.present", mode="embedded")
                        evaluate(handle, f"document.body.style.background='{color}'; true")
                        command(handle, "resize", width=size[0], height=size[1])
                        receiver = native.receiver()
                        bid = int(handle[1:])
                        client.action("chromium_gpu_offer", bid, mechanism="mach-iosurface-v1", endpoint=receiver.endpoint)
                        probe = frame(receiver, lambda f: f.probe)
                        probe.prove()
                        assert client.action("chromium_gpu_confirm", bid)["active"]
                        probe.close()
                        receivers.append((receiver, size, bytes([0, 0, 255, 255]) if color == "red" else bytes([255, 0, 0, 255])))
                    client.send(dict(type="subscribe", sessions=[primary["id"], secondary["id"]]))
                    # Native display color management can slightly shift primaries.
                    # Dimensions and distinct red/blue channels still identify each window.
                    for receiver, size, expected in receivers:
                        captured = frame(receiver, lambda f: not f.probe and (f.width, f.height) == size and all(abs(a - b) <= 16 for a, b in zip(f.sample(f.width // 2, f.height // 2), expected)))
                        captured.close()
                finally:
                    native.close()
                # A real frontend exits through Detach, then a fresh process
                # reconnects to the same two windows and live page state.
                project = args.project.resolve()
                for phase in ("detach", "reconnect"):
                    frontend = ["godot"]
                    if not os.environ.get("GRAFFITTY_TEST_HEADFUL"):
                        frontend += ["--headless"]
                    frontend += ["--path", str(Path(os.environ["GRAFFITTY_TEST_PACK"]).parent if os.environ.get("GRAFFITTY_TEST_PACK") else project)]
                    if os.environ.get("GRAFFITTY_TEST_PACK"):
                        frontend += ["--main-pack", os.environ["GRAFFITTY_TEST_PACK"]]
                    frontend += ["--script", str(project / "tests/chromium_reconnect_smoke.gd")]
                    try:
                        result = subprocess.run(frontend, env=env, capture_output=True, text=True, timeout=60)
                    except subprocess.TimeoutExpired as error:
                        print(error.stdout, error.stderr)
                        raise
                    (root / (phase + ".log")).write_text(result.stdout + result.stderr)
                    assert result.returncode == 0 and "PASS: frontend restored" in result.stdout, (phase, result.stdout[-4000:], result.stderr[:4000])
                    assert "SCRIPT ERROR" not in result.stderr, result.stderr
                    assert evaluate(child, "[window.retained,document.querySelector('input').value]") == ['live-js','unsaved']
                    assert command(child, "chrome-state")["pid"] == original["pid"]
                print("PASS two real frontend exits/reconnects retain both windows and live page state")
                # Closing the main pane promotes the surviving window without
                # terminating Chromium or losing the session's extension files.
                call("chromium.close", chromium=main)
                client.until(lambda: len(topology().get("chromiums", [])) == 1 and topology()["chromiums"][0]["state"].get("mainWindow"))
                survivor = topology()["chromiums"][0]
                assert survivor["id"] == secondary["id"] and survivor["owner"] == source, survivor
                assert evaluate(child, "window.retained") == "live-js"
                assert len(command(child, "tab-new")["tabs"]) == 2
                call("chromium.close", chromium=child)
                print("PASS native resize independence, visible detached windows, shared process/profile, live page retention, independent GPU frames, ownership and main-window promotion")
            except BaseException:
                print((server.directory / "server.log").read_text()[-12000:])
                raise
            finally:
                try:
                    if 'original' in locals():
                        runtime = Path(original['runtimeDirectory'])
                        for name in ('cef.log', 'lifecycle.jsonl'):
                            if (runtime/name).is_file():
                                (root/name).write_bytes((runtime/name).read_bytes())
                finally:
                    client.close()


if __name__ == "__main__":
    main()
