#!/usr/bin/env python3
"""Check CEF startup and renderer operation inside a packaged macOS app.

Usage: python3 tests/chromium/chromium_nested_bundle_e2e.py <Chromium GPU Host.app>
Add --context-menu to exercise macOS Start/Stop Speaking (briefly plays audio).
"""
import contextlib
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import time

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def unregister(root):
    """Launching registers these bundles with Launch Services, which keeps
    listing them after their directory is gone."""
    for bundle in root.rglob("*.app"):
        subprocess.run([LSREGISTER, "-u", str(bundle)], check=False)


def main():
    source = Path(sys.argv[1]).resolve()
    # Clone the framework on APFS without changing the source or live sessions.
    with tempfile.TemporaryDirectory(prefix="/tmp/gft-nested-") as temporary, contextlib.ExitStack() as cleanup:
        root = Path(temporary)
        cleanup.callback(unregister, root)
        outer = root / "Graffitty.app/Contents"
        outer.mkdir(parents=True)
        (outer / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.graffitty.nested-test",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Graffitty",
        }))
        host = outer / "Resources/Chromium GPU Host.app"
        host.parent.mkdir()
        subprocess.run(["cp", "-cR", str(source), str(host)], check=True)
        # CEF interprets this key as a helper-process marker when locating its
        # framework. The host must use its runtime activation policy instead.
        assert not plistlib.loads((host / "Contents/Info.plist").read_bytes()).get("LSUIElement", False)
        assert plistlib.loads((host / "Contents/Info.plist").read_bytes()).get("LSBackgroundOnly") is True
        # Launch Services/crash-dialog relaunch has no Chromium process type.
        # Every installed helper variant must exit cleanly instead of aborting.
        for helper in (host / "Contents/Frameworks").glob("*Helper*.app"):
            info = plistlib.loads((helper / "Contents/Info.plist").read_bytes())
            assert info.get("LSUIElement") is True, helper.name
            binary = helper / "Contents/MacOS" / info["CFBundleExecutable"]
            standalone = subprocess.run([str(binary)], capture_output=True, timeout=10)
            assert standalone.returncode == 0, (helper.name, standalone.stderr)
        print("PASS standalone helper relaunch exits cleanly")
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(root / "control"))
            listener.listen()
            listener.settimeout(60)
            with (root / "stderr.log").open("w+", errors="replace") as log:
                process = subprocess.Popen([
                    str(host / "Contents/MacOS/probe"),
                    "--artifacts", str(root), "--profile", str(root / "profile"),
                    "--server-control", str(root / "control"),
                    "--gpu-endpoint", str(root / "gpu"),
                    "--url", "data:text/html,<title>Nested bundle test</title><h1>Ready</h1>",
                ], stdout=log, stderr=log)
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(15)
                        pending = bytearray()
                        sequence = 0
                        events = []

                        def call(method, params=None, session=None):
                            nonlocal sequence
                            sequence += 1
                            message = dict(id=sequence, method=method, params=params or {})
                            if session:
                                message["sessionId"] = session
                            connection.sendall(json.dumps(message).encode() + b"\0")
                            while True:
                                while b"\0" not in pending:
                                    data = connection.recv(65536)
                                    assert data, "Chromium control connection closed"
                                    pending.extend(data)
                                raw, _, rest = pending.partition(b"\0")
                                pending[:] = rest
                                reply = json.loads(raw)
                                if "method" in reply:
                                    events.append(reply)
                                if reply.get("id") == sequence:
                                    assert "error" not in reply, reply
                                    return reply["result"]

                        assert "product" in call("Browser.getVersion")
                        # Check the live policy after CEF startup, not just the
                        # plist: NSApplication can override LSUIElement.
                        policy = subprocess.check_output([
                            "osascript", "-l", "JavaScript", "-e",
                            "ObjC.import('AppKit'); "
                            f"$.NSRunningApplication.runningApplicationWithProcessIdentifier({process.pid}).activationPolicy",
                        ], text=True).strip()
                        assert policy == "1", f"Chromium host is not an accessory app: {policy}"
                        print("PASS host stays out of Dock/app switcher after CEF startup")
                        deadline = time.monotonic() + 15
                        while True:
                            targets = call("Target.getTargets")["targetInfos"]
                            page = next((t for t in targets if t["type"] == "page"
                                         and t.get("title") == "Nested bundle test"), None)
                            if page:
                                break
                            assert time.monotonic() < deadline, targets
                            time.sleep(.05)
                        session = call("Target.attachToTarget", {
                            "targetId": page["targetId"], "flatten": True,
                        })["sessionId"]
                        result = call("Runtime.evaluate", {
                            "expression": "document.querySelector('h1').textContent",
                            "returnByValue": True,
                        }, session)
                        assert result["result"]["value"] == "Ready", result
                        print("PASS nested app framework lookup, renderer startup, and CDP", flush=True)
                        if "--context-menu" in sys.argv:
                            call("Runtime.evaluate", {"expression": """
                                const h = document.querySelector('h1');
                                h.textContent = 'Chromium speech test. '.repeat(20);
                                const r = document.createRange(); r.selectNodeContents(h);
                                getSelection().removeAllRanges(); getSelection().addRange(r);
                            """}, session)

                            def menu():
                                events.clear()
                                for kind in ("mousePressed", "mouseReleased"):
                                    call("Input.dispatchMouseEvent", dict(
                                        type=kind, button="right", x=30, y=30,
                                        clickCount=1, contextMenuRequest="test"), session)
                                deadline = time.monotonic() + 5
                                while True:
                                    menus = [e["params"] for e in events
                                             if e["method"] == "Graffitty.contextMenu"
                                             and e["params"]["items"]]
                                    if menus:
                                        return menus[-1]
                                    assert time.monotonic() < deadline, events
                                    call("Browser.getVersion")
                                    time.sleep(.05)

                            def item(menu, command):
                                for entry in menu["items"]:
                                    if entry["id"] == command:
                                        return entry
                                    if "items" in entry:
                                        found = item(entry, command)
                                        if found:
                                            return found

                            start = menu()
                            assert item(start, 101)["enabled"], start
                            # Stale selections must not dismiss the current menu.
                            call("Graffitty.contextMenuSelect", {
                                "menu_id": start["id"] + 1, "command_id": 101})
                            call("Graffitty.contextMenuSelect", {
                                "menu_id": start["id"], "command_id": 101})
                            deadline = time.monotonic() + 10
                            while True:
                                stop = menu()
                                if item(stop, 102)["enabled"]:
                                    break
                                assert time.monotonic() < deadline, stop
                                call("Graffitty.contextMenuSelect", {
                                    "menu_id": stop["id"], "command_id": -1})
                                time.sleep(.1)
                            call("Graffitty.contextMenuSelect", {
                                "menu_id": stop["id"], "command_id": 102})
                            call("Browser.getVersion")
                            cancelled = menu()
                            call("Graffitty.contextMenuSelect", {
                                "menu_id": cancelled["id"], "command_id": -1})
                            assert call("Runtime.evaluate", {
                                "expression": "1 + 1", "returnByValue": True,
                            }, session)["result"]["value"] == 2
                            print("PASS speech start/stop, stale selection, dismissal, and surviving renderer")
                        call("Browser.close")
                    assert process.wait(timeout=15) == 0
                    print("PASS nested app framework lookup, renderer startup, CDP, and clean shutdown")
                except Exception:
                    log.seek(0)
                    print(log.read()[-6000:], file=sys.stderr)
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)


if __name__ == "__main__":
    main()
