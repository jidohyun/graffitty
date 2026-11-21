# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Verify that Chromium reports faults and recovers in an isolated profile.

- Kill the host process. Restart the same pane with its pages.
- Kill a page renderer. Keep the host running and reload the page.
- Kill the GPU process. Check that Chromium relaunches it.
- Report a page stuck in script and reload it.

Normal runs use SIGKILL and assert no crash reports. Each macOS crash
report opens a "quit unexpectedly" dialog on the test machine.

`--gpu-abort` repeats GPU crashes until Chromium aborts with
"GPU process isn't usable". That case leaves crash reports.
"""
import argparse
import functools
import glob
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


def helpers(host, kind):
    """The host's helper processes of one Chromium process type."""
    listing = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, check=True).stdout
    found = []
    for line in listing.splitlines():
        pid, parent, command = (line.split(None, 2) + ["", "", ""])[:3]
        if parent == str(host) and f"--type={kind}" in command.split() and "--extension-process" not in command:
            found.append(int(pid))
    return found


def crash_reports():
    """Chromium host crash reports macOS would show as dialogs."""
    return {path for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*"))
            if "probe" in os.path.basename(path)}


def kill(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return pids


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpu-abort", action="store_true", help="also crash the GPU process until Chromium aborts")
    args = parser.parse_args()
    reports_before = crash_reports()
    with tempfile.TemporaryDirectory(prefix="gr-chromium-crash-") as scratch:
        scratch = Path(scratch)
        (scratch / "www").mkdir()
        for name in ("first", "second"):
            (scratch / "www" / f"{name}.html").write_text(f"<!doctype html><title>{name}</title><body style='background:#2080c0'>{name}")
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(scratch / "www"))
        pages = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=pages.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{pages.server_address[1]}"
        path = scratch / "server.json"
        log = (scratch / "server.log").open("w")
        server = subprocess.Popen([BINARY, "server", "--listen", "127.0.0.1:0", "--connection", path,
            "--auth-file", scratch / "auth.json", "--shell", "/bin/sh"], stdout=log, stderr=log)
        try:
            for _ in range(200):
                if path.exists():
                    break
                assert server.poll() is None
                time.sleep(0.05)
            descriptor = json.loads(path.read_text())
            owner = Client(descriptor, chromium_video=["hevc", "h264"])
            pane = owner.topology["panes"][0]["id"]
            request = 0
            def call(method, **params):
                nonlocal request
                request += 1
                owner.action("rpc", pane, request=request, method=method, params=params)
                owner.until(lambda: any(m.get("request") == request for m in owner.messages))
                return next(m for m in owner.messages if m.get("request") == request)
            def rpc(method, **params):
                reply = call(method, **params)
                assert reply["type"] == "ack", reply
                return reply["result"]
            def command(chromium, action, **args):
                ticket = rpc("chromium.command", chromium=chromium, action=action, args=args)["ticket"]
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    result = rpc("chromium.result", chromium=chromium, ticket=ticket)
                    if result is not None:
                        assert "error" not in result, result
                        return result["result"]
                    time.sleep(0.02)
                raise AssertionError("Chromium command timed out")
            def state(bid):
                return next((b["state"] for b in owner.topology.get("chromiums", []) if b["id"] == bid), {})
            def ticketed(method, **params):
                ticket = rpc(method, **params)["_ticket"]
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    result = rpc("chromium.result", chromium=params["chromium"], ticket=ticket)
                    if result is not None:
                        return result
                    time.sleep(0.02)
                raise AssertionError(f"{method} timed out")
            def selected_tab(bid):
                return next((t for t in state(bid).get("tabs", []) if t["selected"]), {})
            def wait(predicate, seconds=30):
                deadline = time.monotonic() + seconds
                owner.ws.settimeout(0.1)
                while not predicate() and time.monotonic() < deadline:
                    try:
                        owner.receive()
                    except Exception as error:
                        if "timed out" not in str(error):
                            raise
                assert predicate(), owner.messages[-3:]

            created = rpc("chromium.create", url=base + "/first.html")["chromium"]
            bid = int(created[1:])
            wait(lambda: state(bid).get("chromiumId", -1) > 0)
            command(created, "tab-new", url=base + "/second.html")
            wait(lambda: len(state(bid).get("tabs", [])) == 2)
            owner.action("subscribe", sessions=[bid])
            wait(lambda: bid in owner.frames)
            tabs = state(bid)["tabs"]
            # The relaunch restores the selected page first, then the others.
            expected = [t["url"] for t in tabs if t["selected"]] + [t["url"] for t in tabs if not t["selected"]]
            pid = state(bid)["pid"]
            os.kill(pid, signal.SIGKILL)
            wait(lambda: state(bid).get("crashed") is True)
            crashed = state(bid)
            assert crashed["error"] == "Chromium host exited (signal: 9 (SIGKILL))", crashed
            assert crashed["restartable"] is True and crashed["lastUrls"] == expected, crashed
            print("PASS a killed Chromium host reports an unexpected stop with its pages")

            rpc("chromium.restart", chromium=created)
            wait(lambda: state(bid).get("chromiumId", -1) > 0 and not state(bid).get("error"))
            wait(lambda: sorted(t["url"] for t in state(bid).get("tabs", [])) == [base + "/first.html", base + "/second.html"])
            assert state(bid)["pid"] != pid, state(bid)
            selected = next(t for t in state(bid)["tabs"] if t["selected"])
            assert selected["url"] == expected[0], state(bid)
            print("PASS restart relaunches the same pane with its tabs, keeping the selected page")
            owner.frames.pop(bid, None)
            wait(lambda: owner.frames.get(bid, {}).get("format") in ("hevc", "h264") and owner.frames[bid]["key"])
            print("PASS video resumes from a keyframe after the relaunch")
            refused = call("chromium.restart", chromium=created)
            # Typed, so a second viewer's Restart is not reported as a failure.
            assert refused["type"] == "error" and refused["error"]["code"] == "chromium_running", refused
            print("PASS a running chromium refuses restart with a typed reason")

            host = state(bid)["pid"]
            assert kill(helpers(host, "renderer")), "The relaunched host has page renderers"
            wait(lambda: selected_tab(bid).get("crashed") is True)
            assert not state(bid).get("error") and state(bid)["pid"] == host, state(bid)
            started = time.monotonic()
            failed = ticketed("chromium.eval", chromium=created, expression="1")
            assert "crashed" in str(failed.get("error")) and time.monotonic() - started < 3, failed
            print("PASS a renderer crash marks the selected page crashed while the browser keeps running")
            command(created, "tab-reload")
            wait(lambda: selected_tab(bid) and "crashed" not in selected_tab(bid))
            owner.frames.pop(bid, None)
            wait(lambda: bid in owner.frames)
            assert ticketed("chromium.eval", chromium=created, expression="40 + 2").get("result") == 42
            # The replacement renderer paints into a new frame sink. Without
            # rebinding, the capturer keeps waiting on the dead one and the
            # pane holds its last image; on a busy page that is intermittent.
            capture = command(created, "cdp", method="Graffitty.diagnostics", params={})
            assert capture.get("recaptures", 0) >= 1 and capture["frameSize"] == capture["previewSize"], capture
            print("PASS reloading a crashed page rebinds capture and resumes video")

            owner.frames.pop(bid, None)
            # A killed process can remain listed briefly; wait for its successor.
            killed = kill(helpers(host, "gpu-process"))
            wait(lambda: set(helpers(host, "gpu-process")) - set(killed))
            ticketed("chromium.eval", chromium=created, expression="document.body.style.background='rgb(40,160,64)'")
            wait(lambda: bid in owner.frames)
            assert not state(bid).get("error"), state(bid)
            print("PASS Chromium relaunches a crashed GPU process and video resumes")
            if args.gpu_abort:
                for _ in range(2):
                    killed = kill(helpers(host, "gpu-process"))
                    wait(lambda: state(bid).get("error") or set(helpers(host, "gpu-process")) - set(killed))
                wait(lambda: state(bid).get("crashed") is True)
                assert "GPU process isn't usable" in state(bid)["error"], state(bid)
                print("PASS repeated GPU crashes end the host with Chromium's own reason:", state(bid)["error"])
                rpc("chromium.restart", chromium=created)
                wait(lambda: state(bid).get("chromiumId", -1) > 0 and not state(bid).get("error"))
                print("PASS a host ended by GPU failures restarts")

            # A page stuck in script keeps its renderer, so nothing above sees
            # it: it just stops painting and answering.
            rpc("chromium.command", chromium=created, action="cdp", args={"method": "Runtime.evaluate",
                "params": {"expression": "setTimeout(()=>{while(true){}},50);1"}})
            wait(lambda: selected_tab(bid).get("notResponding") is True, 20)
            assert not state(bid).get("error") and not selected_tab(bid).get("crashed"), state(bid)
            started = time.monotonic()
            stuck = ticketed("chromium.eval", chromium=created, expression="1")
            assert "not responding" in str(stuck.get("error")) and time.monotonic() - started < 3, stuck
            print("PASS a page stuck in script is reported without waiting for a timeout")
            before = crash_reports()
            command(created, "tab-reload")
            wait(lambda: selected_tab(bid) and not selected_tab(bid).get("notResponding") and not selected_tab(bid).get("crashed"), 20)
            assert ticketed("chromium.eval", chromium=created, expression="6*7").get("result") == 42
            # macOS shows every crash report as a "quit unexpectedly" dialog.
            assert not crash_reports() - before, crash_reports() - before
            print("PASS reloading a stuck page loads it again without crashing anything")
            if not args.gpu_abort:
                left = crash_reports() - reports_before
                assert not left, f"Crash reports macOS would show as dialogs: {sorted(left)}"
                print("PASS the run left no crash report for macOS to show")
            print("CHROMIUM_CRASH_E2E_PASS")
        except Exception:
            log.flush()
            print((scratch / "server.log").read_text()[-4000:], flush=True)
            raise
        finally:
            server.terminate()
            server.wait(timeout=15)
            log.close()
            pages.shutdown()


if __name__ == "__main__":
    main()
