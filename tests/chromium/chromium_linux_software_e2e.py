# /// script
# dependencies = ["websocket-client>=1.8,<2", "pillow>=11"]
# ///
"""Check software browser capture and WebSocket PNG negotiation on GPU-less Linux."""
import argparse
import os
from io import BytesIO
from pathlib import Path
import sys
import subprocess
import time

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "platform/linux"))
from linux_chromium_lifecycle_e2e import Fixture
from chromium_video_e2e import barrier, evaluate
from headless_remote_e2e import Client


def run(args):
    if not args.fence:
        assert not Path("/dev/dri").exists() and not list(Path("/dev").glob("nvidia*")), (
            "Run inside a GPU-less container or VM")
    headless = args.platform == "headless"
    if headless:
        assert not any(os.getenv(key) for key in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET"))
        args.platform = ""  # Let the host select its platform from the empty display environment.
    trace = args.output.resolve() / "fence.trace"
    if args.fence:
        os.environ["GRAFFITTY_TEST_FENCE_TRACE"] = str(trace)
        if args.fence == "poll-error":
            os.environ["GRAFFITTY_TEST_FAIL_DMA_POLL"] = "1"
        if args.fence == "observe":
            os.environ["GRAFFITTY_TEST_OBSERVE_EXPORT"] = "1"
    with Fixture(args) as fixture:
        pane = fixture.rpc("chromium.create", url="about:blank")["chromium"]
        sid = int(pane[1:])
        def browser_state():
            return next((p["state"] for p in fixture.owner.topology.get("chromiums", [])
                         if p["id"] == sid), {})

        initial = "vulkan-opaque-fd" if args.fence else (
            "cdp-screencast" if args.backend == "chrome" else "sealed-memfd")
        fixture.owner.until(lambda: browser_state().get("captureTransport") == initial)
        if headless:
            state = browser_state()
            assert state["ozonePlatform"] == "headless" and state["nativeWindowSupported"] is False, state
        expected = initial
        offered = ["av1", "hevc", "h264"]
        if args.fence:
            state = browser_state()
            pid, target = state["pid"], state["primaryTargetId"]
            assert evaluate(fixture.rpc, pane, "window.fenceTest=42;true")
            expected = "cdp-screencast" if args.fence == "poll-error" else initial
            offered = []  # Exercise PNG reception even on a server with NVENC.
        viewer = Client(fixture.descriptor, chromium_video=offered, chromium_image_format="png")
        try:
            def command(action, *, expected_error=None, **args):
                ticket = fixture.rpc("chromium.command", chromium=pane, action=action, args=args)["ticket"]
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    reply = fixture.rpc("chromium.result", chromium=pane, ticket=ticket)
                    if reply is not None:
                        if expected_error:
                            assert expected_error in reply["error"]["message"], reply
                        else:
                            assert "error" not in reply, reply
                        return
                    time.sleep(.01)
                raise AssertionError(f"{action} timed out")

            def paint(color):
                assert evaluate(fixture.rpc, pane, f"document.body.style.background='rgb{color}';true")

            def expect(width, height, color):
                def received():
                    if viewer.frames.get(sid, {}).get("format") != "png":
                        return False
                    with Image.open(BytesIO(viewer.payloads[sid])) as image:
                        return (image.format == "PNG" and image.size == (width, height) and
                                image.convert("RGB").getpixel((width // 2, height // 2)) == color)

                try:
                    viewer.until(received)
                except (AssertionError, TimeoutError):
                    state = next((p["state"] for p in viewer.topology.get("chromiums", [])
                                  if p["id"] == sid), browser_state())
                    print("Capture diagnostics", {k: state.get(k) for k in
                          ("captureTransport", "gpuFrames", "sentFrames", "captureError",
                           "nativeVisible", "ozonePlatform")}, viewer.frames.get(sid), flush=True)
                    log = Path(state["runtimeDirectory"]) / "cef.log"
                    if log.is_file():
                        (fixture.out / "capture-failure.log").write_bytes(log.read_bytes())
                    raise
                print(f"PASS {args.backend} {expected} -> WebSocket PNG {width}x{height} RGB {color}",
                      flush=True)

            viewer.action("subscribe", sessions=[sid])
            for width, height, color in ((640, 480, (208, 32, 32)), (720, 360, (32, 64, 208))):
                command("resize", width=width, height=height)
                paint(color)
                expect(width, height, color)

            if args.fence:
                fixture.owner.until(lambda: browser_state().get("captureTransport") == expected)
                state = browser_state()
                assert (state["pid"], state["primaryTargetId"]) == (pid, target)
                if args.fence == "poll-error":
                    assert state["gpuFrames"] == 1 and state["sentFrames"] == 0, state
                else:
                    fixture.owner.until(lambda: browser_state().get("sentFrames", 0) >= 2)
                assert evaluate(fixture.rpc, pane, "window.fenceTest") == 42
                log = (Path(state["runtimeDirectory"]) / "cef.log").read_text()
                mode = "exported sync_file" if args.fence == "observe" else "implicit POLLIN"
                assert log.count("DMA-BUF writer wait: " + mode) == 1
                assert log.count("switching to software capture via CDP") == int(args.fence == "poll-error")
                events = trace.read_text()
                if args.fence != "observe":
                    assert events.count("ENOTTY") == 1
                observed = {"observe": "export ", "implicit": "implicit-", "poll-error": "POLLERR"}
                assert observed[args.fence] in events, events
                print(f"PASS {args.fence}, same browser and page, {browser_state()['sentFrames']} GPU frames sent", flush=True)

            if headless:
                command("chrome-native", expected_error="Native presentation requires a display server")
            elif args.backend == "chrome":
                command("chrome-native")
                paint((48, 160, 64))
                command("chrome-world")
                expect(720, 360, (48, 160, 64))

            viewer.action("subscribe", sessions=[])
            barrier(viewer, fixture.pane, 1)
            paint((200, 112, 48))
            viewer.action("subscribe", sessions=[sid])
            expect(720, 360, (200, 112, 48))

            if args.verify_h264:
                codec_viewer = Client(fixture.descriptor, chromium_video=["h264"])
                try:
                    codec_viewer.action("subscribe", sessions=[sid])
                    codec_viewer.until(lambda: codec_viewer.frames.get(sid, {}).get("format") == "h264")
                    header = codec_viewer.frames[sid]
                    assert header["key"] and (header["width"], header["height"]) == (720, 360), header
                    rgb = subprocess.run(["ffmpeg", "-v", "error", "-f", "h264", "-i", "pipe:0",
                        "-frames:v", "1", "-vf", "crop=2:2", "-pix_fmt", "rgb24", "-f", "rawvideo",
                        "pipe:1"], input=codec_viewer.payloads[sid], capture_output=True,
                        check=True, timeout=10).stdout
                    assert len(rgb) == 12 and max(abs(a-b) for a, b in zip(rgb[:3], (200, 112, 48))) <= 8, rgb
                    print(f"PASS WebSocket H.264 keyframe 720x360 center RGB {tuple(rgb[:3])}", flush=True)
                finally:
                    codec_viewer.ws.close()
        finally:
            viewer.ws.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--backend", required=True, choices=("alloy", "chrome"))
    parser.add_argument("--platform", default="x11", choices=("x11", "wayland", "headless"))
    parser.add_argument("--fence", choices=("implicit", "poll-error", "observe"),
                        help="Test a real GPU with a host linked to linux_missing_fence_ioctl.c")
    parser.add_argument("--verify-h264", action="store_true", help="Also decode a hardware H.264 keyframe")
    run(parser.parse_args())
