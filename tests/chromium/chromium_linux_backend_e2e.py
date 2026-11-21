"""Check CEF control and Vulkan pixels on Linux under X11 or native Wayland.

Build the Linux CEF fork and the CMake chromium_capture_test target.
The fixture clears DISPLAY when exercising native Wayland.
"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

from chromium_native_backend_e2e import Host as CommonHost, Site


class Capture:
    def __init__(self, library, endpoint):
        self.dll = C.CDLL(str(library))
        self.dll.gft_linux_capture_new.argtypes = [C.c_char_p]
        self.dll.gft_linux_capture_new.restype = C.c_void_p
        self.dll.gft_linux_capture_free.argtypes = [C.c_void_p]
        self.dll.gft_linux_capture_free.restype = None
        self.dll.gft_linux_capture_sample.argtypes = [C.c_void_p, C.POINTER(C.c_uint32),
                                                     C.POINTER(C.c_uint32), C.POINTER(C.c_uint8)]
        self.dll.gft_linux_capture_sample.restype = C.c_int
        self.handle = self.dll.gft_linux_capture_new(endpoint.encode())
        assert self.handle, "Hardware Vulkan receiver unavailable"
        self.frames, self.latest, self.paused = 0, None, False

    def receive(self):
        if self.paused:
            return
        width, height, rgba = C.c_uint32(), C.c_uint32(), (C.c_uint8 * 4)()
        result = self.dll.gft_linux_capture_sample(self.handle, C.byref(width), C.byref(height), rgba)
        assert result >= 0, "GPU import/readback failed"
        if result:
            self.frames += 1
            self.latest = (width.value, height.value, tuple(rgba))

    def close(self):
        self.dll.gft_linux_capture_free(self.handle)


class Host(CommonHost):
    def __init__(self, args, backend, directory, url):
        self.backend, self.directory = backend, directory
        directory.mkdir()
        self.socket_dir = tempfile.TemporaryDirectory(prefix="gft-cef-")
        path = str(Path(self.socket_dir.name) / "control")
        endpoint = "gft-linux-test-" + uuid.uuid4().hex
        self.capture = Capture(args.capture_library, endpoint)
        self.log = (directory / "host.log").open("wb")
        self.pipe = None
        self.pending, self.replies, self.events = bytearray(), {}, []
        self.sequence, self.session = 0, None
        environment = dict(os.environ, GRAFFITTY_CHROMIUM_OZONE_PLATFORM=args.platform)
        if args.platform == "wayland":
            environment.pop("DISPLAY", None)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(30)
            self.process = subprocess.Popen([
                str(args.host), "--backend", backend, "--artifacts", str(directory),
                "--profile", str(directory / "profile"), "--server-control", path,
                "--server-pid", str(os.getpid()), "--gpu-endpoint", endpoint, "--url", url,
            ], stdout=self.log, stderr=self.log, env=environment)
            try:
                self.pipe, _ = listener.accept()
                pid, uid, _ = struct.unpack("3i", self.pipe.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                assert pid == self.process.pid and uid == os.getuid(), "Unexpected host peer"
                self.pipe.setblocking(False)
            except BaseException:
                self.process.kill()
                self.process.wait(timeout=10)
                if self.pipe:
                    self.pipe.close()
                self.capture.close()
                self.log.close()
                self.socket_dir.cleanup()
                raise

    def pump(self):
        self.capture.receive()
        while True:
            try:
                data = self.pipe.recv(65536)
            except BlockingIOError:
                break
            if not data:
                break
            self.pending.extend(data)
        while b"\0" in self.pending:
            raw, _, rest = self.pending.partition(b"\0")
            self.pending[:] = rest
            message = json.loads(raw)
            if "id" in message:
                self.replies[message["id"]] = message
            else:
                self.events.append(message)

    def write(self, data):
        self.pipe.settimeout(10)
        try:
            self.pipe.sendall(data)
        finally:
            self.pipe.setblocking(False)

    def frame(self, color, size=(640, 480)):
        def matches():
            viewport = self.js("[innerWidth,innerHeight,Math.ceil(innerWidth*devicePixelRatio),Math.ceil(innerHeight*devicePixelRatio)]")
            latest = self.capture.latest
            return (viewport[:2] == list(size) and latest and latest[:2] == tuple(viewport[2:])
                    and latest[2][3] == 255
                    and all(abs(a-b) < 5 for a, b in zip(latest[2], color)))
        self.wait(matches, "captured page pixels and viewport size")

    def close(self):
        # Normal host shutdown closes the GPU stream before control EOF.
        self.capture.paused = True
        try:
            if self.process.poll() is None:
                self.call("Browser.close")
                assert self.process.wait(timeout=20) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=10)
            self.pipe.close()
            self.capture.close()
            self.log.close()
            self.socket_dir.cleanup()


def run(args, backend, base):
    directory = args.artifacts / (backend + "-" + uuid.uuid4().hex[:8])
    host = Host(args, backend, directory, base + "/red")
    try:
        state = host.wait(lambda: (s if len((s := host.diagnostics()).get("pageTargets", [])) == 1 else None), "initial page")
        assert state["ozonePlatform"] == args.platform, state
        assert state["visibleWindows"] == 0, state
        assert state["nativeWindowSupported"] == (backend == "chrome"), state
        red = state["pageTargets"][0]
        host.attach(red)
        host.wait(lambda: host.js("document.readyState==='complete'"), "loaded page")
        host.call("Graffitty.resize", dict(width=640, height=480))
        host.call("Graffitty.capture", dict(enabled=True))
        host.frame((208, 32, 32))
        host.js("document.cookie='shared=yes; path=/';localStorage.setItem('shared','yes')")
        # Real repainting, not just JS timers or CDP screenshot success.
        host.js("window.paintTimer=setInterval(()=>document.body.style.background=++ticks%2?'#2040d0':'#d02020',40)")
        before = host.capture.frames
        host.wait(lambda: host.capture.frames >= before + 20, "continuous offscreen GPU frames")
        host.js("clearInterval(paintTimer);document.body.style.background='#d02020'")
        host.frame((208, 32, 32))
        blue = host.call("Graffitty.createTab", dict(url=base + "/blue"))["targetId"]
        host.attach(blue)
        host.wait(lambda: host.js("location.pathname==='/blue' && document.readyState==='complete'"), "new tab")
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'")
        host.frame((32, 64, 208))
        host.call("Graffitty.moveTab", dict(targetId=blue, index=0))
        host.wait(lambda: host.diagnostics()["pageTargets"] == [blue, red], "native tab order")
        host.call("Graffitty.select", dict(targetId=red))
        host.attach(red)
        host.frame((208, 32, 32))
        if backend == "chrome":
            for _ in range(3):
                host.call("Graffitty.present", dict(mode="native"))
                host.wait(lambda: host.diagnostics()["nativeUIVisible"], "native Wayland/X11 window")
                host.call("Graffitty.present", dict(mode="embedded"))
                host.wait(lambda: host.diagnostics()["visibleWindows"] == 0, "window unmapped")
                # Change color so an old cached frame cannot pass the return test.
                host.js("document.body.style.background='#20c040'")
                host.frame((32, 192, 64))
                host.js("document.body.style.background='#d02020'")
                host.frame((208, 32, 32))
        else:
            host.call("Graffitty.present", dict(mode="native"), error=True)
        host.capture.paused = True
        host.call("Graffitty.resize", dict(width=900, height=700))
        host.js("document.body.style.background='#20c040'")
        time.sleep(.2)
        host.capture.paused = False
        host.frame((32, 192, 64), (900, 700))
        host.call("Target.closeTarget", dict(targetId=red))
        host.wait(lambda: host.diagnostics()["pageTargets"] == [blue], "original owner closed")
        host.attach(blue)
        host.frame((32, 64, 208), (900, 700))
        if backend == "alloy":
            # Resize retries must stop once the requested frame arrives.
            time.sleep(.2)
            host.pump()
            settled = host.capture.frames
            until = time.monotonic() + 1
            while time.monotonic() < until:
                host.pump()
                time.sleep(.02)
            assert host.capture.frames <= settled + 2, "Static capture kept refreshing after resize"
        state = host.diagnostics()
        assert state["errors"] == 0 and state["visibleWindows"] == 0, state
    except BaseException:
        if host.process.poll() is None:
            try:
                (directory / "failure.json").write_text(json.dumps(dict(
                    diagnostics=host.diagnostics(), frame=host.capture.latest,
                    viewport=host.js("[innerWidth,innerHeight,document.visibilityState]")), indent=2))
            except Exception:
                pass
        raise
    finally:
        host.close()
    (directory / "result.json").write_text(json.dumps(dict(platform=args.platform, backend=backend,
        frames=host.capture.frames, diagnostics=state), indent=2))
    print("PASS", args.platform, backend, "GPU pixels, animation, tabs, storage, presentation, backpressure, owner replacement")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--capture-library", type=Path, required=True)
    parser.add_argument("--platform", choices=["x11", "wayland"], required=True)
    parser.add_argument("--backend", choices=["alloy", "chrome", "both"], default="both")
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    args.host, args.capture_library, args.artifacts = (p.resolve() for p in (args.host, args.capture_library, args.artifacts))
    args.artifacts.mkdir(parents=True, exist_ok=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Site) as web:
        threading.Thread(target=web.serve_forever, daemon=True).start()
        try:
            for backend in ["alloy", "chrome"] if args.backend == "both" else [args.backend]:
                run(args, backend, f"http://127.0.0.1:{web.server_port}")
        finally:
            web.shutdown()


if __name__ == "__main__":
    main()
