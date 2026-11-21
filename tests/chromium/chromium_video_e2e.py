# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real hardware video negotiation, independent renditions, late join and fallback."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


def evaluate(rpc, chromium, expression):
    ticket = rpc("chromium.command", chromium=chromium, action="cdp", args={
        "method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": True}})["ticket"]
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = rpc("chromium.result", chromium=chromium, ticket=ticket)
        if result is not None:
            assert "error" not in result, result
            return result["result"]["result"]["value"]
        time.sleep(.01)
    raise AssertionError("Page evaluation timed out")


def barrier(client, pane, request):
    client.action("rpc", pane, request=request, method="session.capture", params={})
    client.until(lambda: any(v.get("request") == request for v in client.messages))
    reply = next(v for v in client.messages if v.get("request") == request)
    assert reply["type"] == "ack", reply


def render_scale(rpc, owner, descriptor, clients):
    """Chromium renders at its largest viewer's displayed size without reflow."""
    created = rpc("chromium.create", url="about:blank")["chromium"]
    sid = int(created[1:])
    owner.until(lambda: any(b["id"] == sid and b["state"].get("chromiumId", -1) > 0
                           for b in owner.topology.get("chromiums", [])))
    rpc("chromium.command", chromium=created, action="resize", args={"width": 1000, "height": 700})
    assert evaluate(rpc, created, "addEventListener('mousedown',e=>window.press=[e.clientX,e.clientY]);"
        "addEventListener('resize',()=>{if(innerWidth!=1000||innerHeight!=700)(window.resizes||=[]).push([innerWidth,innerHeight])});true")
    viewer = Client(descriptor, chromium_video=["h264"])
    clients.append(viewer)
    viewer.action("subscribe", sessions=[sid])
    source = lambda client: (client.frames.get(sid, {}).get("source_width"), client.frames.get(sid, {}).get("source_height"))
    viewer.until(lambda: source(viewer) == (1000, 700))
    print("PASS a viewer without a displayed size receives CSS resolution")
    for requested, expected in [(240, (342, 240)), (1440, (1000, 700)), (144, (206, 144)), (720, (1000, 700)), (360, (514, 360))]:
        viewer.action("chromium_stream", viewports={str(sid): requested})
        viewer.until(lambda: source(viewer) == expected)
        assert (viewer.frames[sid]["width"], viewer.frames[sid]["height"]) == expected, viewer.frames[sid]
        inner_width, inner_height, outer_width, ratio = evaluate(rpc, created, "[innerWidth,innerHeight,outerWidth,devicePixelRatio]")
        assert [inner_width, inner_height, ratio] == [1000, 700, 1], "Render scale must not change website layout"
        # A window wider than its page looks like an open developer-tools panel.
        assert outer_width <= inner_width, outer_width
    resizes = evaluate(rpc, created, "window.resizes||null")
    assert resizes is None, f"The page saw intermediate CSS viewports: {resizes}"
    print("PASS render resolution follows displayed size without changing website layout")
    viewer.action("chromium_stream", viewports={str(sid): 240})
    viewer.until(lambda: source(viewer) == (342, 240))
    for kind in ("mousePressed", "mouseReleased"):
        rpc("chromium.input", chromium=created, event={"method": "Input.dispatchMouseEvent", "params": {
            "type": kind, "x": 600, "y": 400, "button": "left", "buttons": int(kind == "mousePressed"), "clickCount": 1}})
    deadline = time.monotonic() + 5
    while evaluate(rpc, created, "window.press||null") != [600, 400] and time.monotonic() < deadline:
        time.sleep(.05)
    assert evaluate(rpc, created, "window.press||null") == [600, 400], "CSS input coordinates survive render scaling"
    print("PASS input coordinates remain CSS pixels at reduced render scale")
    assert evaluate(rpc, created, "document.body.style.height='10000px';document.documentElement.style.scrollBehavior='auto';scrollTo(0,0);window.wheelDelta=null;addEventListener('wheel',e=>window.wheelDelta=e.deltaY,{passive:true});true")
    evaluate(rpc, created, "window.wheelReady=false;requestAnimationFrame(()=>requestAnimationFrame(()=>window.wheelReady=true));true")
    deadline = time.monotonic() + 3
    while not evaluate(rpc, created, "window.wheelReady") and time.monotonic() < deadline:
        time.sleep(.03)
    assert evaluate(rpc, created, "window.wheelReady"), "Scrollable layout must reach the compositor before input"
    rpc("chromium.input", chromium=created, event={"method": "Input.dispatchMouseEvent", "params": {
        "type": "mouseWheel", "x": 600, "y": 400, "deltaX": 0, "deltaY": 210}})
    deadline = time.monotonic() + 3
    while abs(evaluate(rpc, created, "scrollY") - 210) > 5 and time.monotonic() < deadline:
        time.sleep(.03)
    offset = evaluate(rpc, created, "scrollY")
    print("WHEEL_SCALE_DIAGNOSTICS", json.dumps({"scroll": offset, "event_delta": evaluate(rpc, created, "window.wheelDelta")}), flush=True)
    assert abs(offset - 210) <= 5, f"CSS wheel distance changes with render scale: {offset} instead of 210"
    print("PASS wheel scrolling retains CSS distance at reduced render scale")
    larger = Client(descriptor, chromium_video=["h264"])
    clients.append(larger)
    larger.action("subscribe", sessions=[sid])
    larger.action("chromium_stream", viewports={str(sid): 1080})
    larger.until(lambda: source(larger) == (1000, 700))
    viewer.until(lambda: source(viewer) == (1000, 700))
    assert (viewer.frames[sid]["width"], viewer.frames[sid]["height"]) == (342, 240), viewer.frames[sid]
    larger.action("subscribe", sessions=[])
    viewer.until(lambda: source(viewer) == (342, 240))
    viewer.action("subscribe", sessions=[])
    print("PASS the largest viewer sets shared render resolution while smaller renditions stay small")


def main():
    with tempfile.TemporaryDirectory(prefix="gr-video-") as scratch:
        descriptor_path = Path(scratch) / "server.json"
        log = open(Path(scratch) / "server.log", "w")
        server = subprocess.Popen([BINARY, "server", "--listen", "127.0.0.1:0",
            "--connection", descriptor_path, "--auth-file", Path(scratch) / "auth.json",
            "--shell", "/bin/sh"], stdout=log, stderr=log)
        clients = []
        try:
            for _ in range(200):
                if descriptor_path.exists():
                    break
                assert server.poll() is None
                time.sleep(.025)
            descriptor = json.loads(descriptor_path.read_text())
            owner = Client(descriptor, chromium_video=["h264", "hevc", "av1"])
            clients.append(owner)
            pane = owner.topology["panes"][0]["id"]
            request = 0
            def rpc(method, **params):
                nonlocal request
                request += 1
                owner.action("rpc", pane, request=request, method=method, params=params)
                owner.until(lambda: any(v.get("request") == request for v in owner.messages))
                result = next(v for v in owner.messages if v.get("request") == request)
                assert result["type"] == "ack", result
                return result["result"]
            chromium = rpc("chromium.create", url="about:blank")
            bid = int(chromium["chromium"][1:])
            owner.until(lambda: any(b["id"] == bid and b["state"].get("chromiumId", -1) > 0
                                   for b in owner.topology.get("chromiums", [])))
            if os.uname().sysname == "Darwin":
                state = next(b["state"] for b in owner.topology["chromiums"] if b["id"] == bid)
                assert state["captureTransport"] == "iosurface", state
                print("PASS server captures GPU surfaces, not CDP images")
            owner.action("subscribe", sessions=[bid])
            owner.until(lambda: bid in owner.frames)
            first = owner.frames[bid]
            assert first["format"] in ("av1", "hevc", "h264"), first
            if os.uname().sysname == "Darwin":
                assert first["format"] == "hevc", first
            assert first["key"] and len(owner.payloads[bid]) > 100
            codec = first["format"]
            print("PASS preferred hardware codec:", codec)

            # A late subscriber to a static page gets a decodable keyframe.
            same = Client(descriptor, chromium_video=[codec])
            clients.append(same)
            same.action("subscribe", sessions=[bid])
            same.until(lambda: bid in same.frames)
            assert same.frames[bid]["key"]
            assert same.frames[bid]["epoch"] == first["epoch"]
            print("PASS late client shares rendition and starts at a keyframe")

            baseline = Client(descriptor, chromium_video=["h264"])
            clients.append(baseline)
            baseline.action("subscribe", sessions=[bid])
            baseline.until(lambda: bid in baseline.frames)
            assert baseline.frames[bid]["format"] == "h264", baseline.frames[bid]
            assert baseline.frames[bid]["key"]
            print("PASS independent H.264 client does not downgrade HEVC client")

            unsupported = Client(descriptor, chromium_video=[], chromium_image_format=None)
            clients.append(unsupported)
            unsupported.action("subscribe", sessions=[bid])
            unsupported.until(lambda: bid in unsupported.frames)
            assert unsupported.frames[bid]["format"] == "error"
            print("PASS unsupported capability intersection reports an explicit error")

            compatible = Client(descriptor, chromium_video=[], chromium_image_format="png")
            clients.append(compatible)
            compatible.action("subscribe", sessions=[bid])
            compatible.until(lambda: bid in compatible.frames)
            assert compatible.frames[bid]["format"] == "png"
            assert compatible.payloads[bid].startswith(bytes([137,80,78,71]))
            print("PASS explicit PNG fallback keeps clients without shared hardware usable")

            owner.action("chromium_video_reject", bid, codec=codec)
            owner.until(lambda: owner.frames.get(bid, {}).get("format") == "h264")
            assert owner.frames[bid]["key"]
            print("PASS decoder failure renegotiates H.264 with a keyframe")

            # A device can run out of hardware decoders for one more stream.
            # The refusal is that pane's alone: another browser on the same
            # client still gets the client's best codec.
            other = rpc("chromium.create", url="about:blank")
            oid = int(other["chromium"][1:])
            owner.action("subscribe", sessions=[bid, oid])
            owner.until(lambda: owner.frames.get(oid, {}).get("format") == codec)
            assert owner.frames[bid]["format"] == "h264"
            print("PASS one pane's decoder failure leaves the client's other streams on their codec")
            owner.action("subscribe", sessions=[bid])
            rpc("chromium.close", chromium=other["chromium"])

            # Resize must create a new generation; existing decoder references cannot survive.
            previous = owner.frames[bid]["epoch"]
            rpc("chromium.command", chromium=chromium["chromium"], action="resize",
                args={"width": 800, "height": 600})
            owner.until(lambda: owner.frames.get(bid, {}).get("epoch") != previous)
            frame = owner.frames[bid]
            assert frame["key"] and frame["width"] == 800 and frame["height"] == 600, frame
            print("PASS resize starts a fresh video generation with its dimensions")
            # Static pages have no animation to repair a lost resize paint.
            # Alternate sizes repeatedly, requiring the real encoded surface
            # and CSS viewport to converge each time, then restore the fixture.
            for width, height in [(912, 608), (800, 600)] * 6:
                rpc("chromium.command", chromium=chromium["chromium"], action="resize",
                    args={"width": width, "height": height})
                owner.until(lambda: (owner.frames[bid].get("source_width"), owner.frames[bid].get("source_height")) == (width, height))
                frame = owner.frames[bid]
                assert frame["key"] and (frame["width"], frame["height"]) == (width, height), frame
                assert evaluate(rpc, chromium["chromium"], "[innerWidth,innerHeight]") == [width, height]
            print("PASS twelve static-page resizes deliver matching GPU frames and CSS viewports")
            before_reset = owner.frames[bid]["frame"]
            owner.action("chromium_video_reset", bid)
            # Packets already queued before reset can arrive first. Drain an
            # ordered control barrier before requiring the recovery keyframe.
            barrier(owner, pane, 9998)
            owner.until(lambda: owner.frames.get(bid, {}).get("key", False)
                        and owner.frames[bid]["frame"] > before_reset)
            print("PASS decoder resynchronization restarts at a keyframe")
            # Independent same-codec profiles keep the source chromium unchanged.
            low = Client(descriptor, chromium_video=["h264"], chromium_stream={"max_height":360,"fps":15,"bitrate_kbps":2000})
            clients.append(low)
            low.action("subscribe", sessions=[bid])
            low.action("chromium_stream", viewports={str(bid):360})
            low.until(lambda: low.frames.get(bid, {}).get("height") == 360)
            small = low.frames[bid]
            assert small["width"] == 480 and small["source_width"] == 800 and small["source_height"] == 600, small
            assert owner.frames[bid]["width"] == 800
            assert small["epoch"] != owner.frames[bid]["epoch"]
            print("PASS low-resolution client retains full chromium input coordinates and independent quality")
            adaptive = Client(descriptor, chromium_video=["h264"])
            clients.append(adaptive)
            adaptive.action("subscribe", sessions=[bid])
            adaptive.until(lambda: bid in adaptive.frames)
            source_size = (800, 600)
            def page_viewport():
                ticket = rpc("chromium.command", chromium=chromium["chromium"], action="cdp", args={
                    "method":"Runtime.evaluate", "params":{"expression":"[innerWidth,innerHeight]", "returnByValue":True}})["ticket"]
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    result = rpc("chromium.result", chromium=chromium["chromium"], ticket=ticket)
                    if result is not None:
                        assert "error" not in result, result
                        return result["result"]["result"]["value"]
                    time.sleep(.01)
                raise AssertionError("Page viewport evaluation timed out")
            assert page_viewport() == list(source_size)
            for requested, expected in [(144, (192, 144)), (240, (320, 240)), (360, (480, 360)), (540, (720, 540)), (1080, source_size)]:
                previous_epoch = adaptive.frames[bid]["epoch"]
                adaptive.action("chromium_stream", viewports={str(bid): requested})
                adaptive.until(lambda: (adaptive.frames[bid]["width"], adaptive.frames[bid]["height"]) == expected)
                resized = adaptive.frames[bid]
                assert (resized["source_width"], resized["source_height"]) == source_size, resized
                assert resized["key"] and resized["epoch"] != previous_epoch, resized
                assert page_viewport() == list(source_size), "Quality changes must not reflow the shared page"
            print("PASS automatic viewport quality grows and shrinks independently of page dimensions")
            # Produce non-key frames so a redundant viewport message cannot hide
            # a cursor reset behind replaying the same cached startup keyframe.
            rpc("chromium.command", chromium=chromium["chromium"], action="cdp", args={
                "method": "Runtime.evaluate", "params": {"expression":
                    "window.streamTick=0;window.streamTimer=setInterval(()=>document.body.style.background=(++streamTick%2?'#20c050':'#dc3cb4'),33)"}})
            adaptive.until(lambda: adaptive.frames[bid]["sequence"] > 3)
            stable_epoch = adaptive.frames[bid]["epoch"]
            stable_sequence = adaptive.frames[bid]["sequence"]
            adaptive.action("chromium_stream", viewports={str(bid): 1000})
            barrier(adaptive, pane, 10001)
            assert adaptive.frames[bid]["epoch"] == stable_epoch, adaptive.frames[bid]
            assert adaptive.frames[bid]["sequence"] >= stable_sequence, adaptive.frames[bid]
            adaptive.until(lambda: adaptive.frames[bid]["sequence"] > stable_sequence)
            assert adaptive.frames[bid]["epoch"] == stable_epoch, adaptive.frames[bid]
            # The separately capped rendition must still honor its 360p limit.
            low.action("chromium_stream", viewports={str(bid): 1080})
            barrier(low, pane, 10002)
            assert low.frames[bid]["height"] == 360, low.frames[bid]
            rpc("chromium.command", chromium=chromium["chromium"], action="cdp", args={
                "method": "Runtime.evaluate", "params": {"expression": "clearInterval(window.streamTimer)"}})
            adaptive.action("subscribe", sessions=[])
            print("PASS equivalent viewport requests preserve the live stream and explicit resolution caps")
            low.action("subscribe", sessions=[])
            # Ordered RPC acknowledgement drains any frames queued before unsubscribe.
            barrier(low, pane, 9999)
            low.frames.clear()
            low.action("chromium_stream", viewports={str(bid):720})
            rpc("chromium.command", chromium=chromium["chromium"], action="resize", args={"width":900,"height":600})
            barrier(low, pane, 10000)
            assert bid not in low.frames
            low.action("subscribe", sessions=[bid])
            low.action("chromium_stream", viewports={str(bid):360})
            low.until(lambda:low.frames.get(bid,{}).get("source_width")==900)
            assert low.frames[bid]["key"]
            print("PASS inactive tab receives no video and resumes with a fresh keyframe")
            if os.uname().sysname == "Darwin":
                render_scale(rpc, owner, descriptor, clients)
            print("CHROMIUM_VIDEO_E2E_PASS")
        except Exception:
            print("VIDEO_FAILURE_FRAMES", json.dumps([client.frames for client in clients]), flush=True)
            try:
                ticket = rpc("chromium.command", chromium=chromium["chromium"], action="chrome-state")["ticket"]
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    diagnostics = rpc("chromium.result", chromium=chromium["chromium"], ticket=ticket)
                    if diagnostics is not None:
                        print("VIDEO_FAILURE_HOST", json.dumps(diagnostics), flush=True)
                        break
                    time.sleep(.05)
            except Exception as diagnostic_error:
                print("VIDEO_FAILURE_DIAGNOSTIC_ERROR", str(diagnostic_error), flush=True)
            log.flush()
            print(Path(scratch, "server.log").read_text(), flush=True)
            raise
        finally:
            for client in clients:
                client.ws.close()
            server.terminate()
            server.wait(timeout=15)
            log.close()


if __name__ == "__main__":
    main()
