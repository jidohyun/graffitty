"""Test both Windows CEF backends with private control and real D3D frames.

1. Build the CMake chromium_capture_test target.
2. Run in an interactive desktop session with --host and --capture-library.

The test starts its own browser and server. Artifacts include host logs
and measured tab latencies.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import struct
import threading
import time
import traceback
import uuid
import zlib


class Site(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/favicon.png":
            def chunk(name, data):
                return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
            body = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
            body += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\x60\x20\xff" * 2) * 2)) + chunk(b"IEND", b"")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        color = {"/red": "#d02020", "/blue": "#2040d0", "/green": "#20c040"}.get(self.path, "#d02020")
        body = f"""<!doctype html><title>{self.path}</title>
        <link rel=icon href=/favicon.png>
        <style>html,body{{margin:0;background:{color};height:2000px}}</style>
        <button id=button onclick="window.clicked=(window.clicked||0)+1">Click</button>
        <select><option>First</option><option>Second</option></select>
        <script>window.ticks=0;function tick(){{++ticks;requestAnimationFrame(tick)}}tick()</script>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Capture:
    def __init__(self, library, name):
        self.dll = C.CDLL(str(library))
        for method, result, arguments in [
            ("gw_capture_new", C.c_void_p, [C.c_char_p]),
            ("gw_capture_free", None, [C.c_void_p]),
            ("gw_capture_receive", C.c_void_p, [C.c_void_p, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)]),
            ("gw_surface_rgba", C.c_int, [C.c_void_p, C.c_void_p]),
            ("gw_surface_free", None, [C.c_void_p]),
        ]:
            function = getattr(self.dll, method)
            function.restype, function.argtypes = result, arguments
        self.handle = self.dll.gw_capture_new(name.encode())
        assert self.handle, "Could not create the D3D receiver"
        self.frames = 0
        self.latest = None
        self.paused = False

    def receive(self):
        if self.paused:
            return
        width, height = C.c_uint32(), C.c_uint32()
        surface = self.dll.gw_capture_receive(self.handle, C.byref(width), C.byref(height))
        if not surface:
            return
        try:
            pixels = C.create_string_buffer(width.value * height.value * 4)
            assert self.dll.gw_surface_rgba(surface, pixels) == 0, "D3D texture readback failed"
            offset = (height.value // 2 * width.value + width.value // 2) * 4
            self.latest = (width.value, height.value, tuple(pixels.raw[offset:offset + 4]))
            self.frames += 1
        finally:
            self.dll.gw_surface_free(surface)

    def close(self):
        self.dll.gw_capture_free(self.handle)


class Host:
    def __init__(self, args, backend, directory, url):
        self.backend = backend
        self.directory = directory
        directory.mkdir()
        self.kernel = C.WinDLL("kernel32", use_last_error=True)
        for name, result, arguments in [
            ("CreateNamedPipeW", W.HANDLE, [W.LPCWSTR, W.DWORD, W.DWORD, W.DWORD, W.DWORD, W.DWORD, W.DWORD, C.c_void_p]),
            ("ConnectNamedPipe", W.BOOL, [W.HANDLE, C.c_void_p]),
            ("GetNamedPipeClientProcessId", W.BOOL, [W.HANDLE, C.POINTER(W.ULONG)]),
            ("ReadFile", W.BOOL, [W.HANDLE, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.c_void_p]),
            ("WriteFile", W.BOOL, [W.HANDLE, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.c_void_p]),
            ("CloseHandle", W.BOOL, [W.HANDLE]),
        ]:
            function = getattr(self.kernel, name)
            function.restype, function.argtypes = result, arguments
        endpoint = "gft-native-test-" + uuid.uuid4().hex
        pipe = r"\\.\pipe" + "\\" + endpoint
        self.pipe = self.kernel.CreateNamedPipeW(pipe, 3 | 0x80000, 1, 1, 65536, 65536, 0, None)
        assert self.pipe != W.HANDLE(-1).value, C.WinError(C.get_last_error())
        self.capture = Capture(args.capture_library, endpoint)
        self.log = (directory / "host.log").open("wb")
        self.process = subprocess.Popen([
            str(args.host), "--backend", backend, "--artifacts", str(directory),
            "--profile", str(directory / "profile"), "--server-control", pipe,
            "--server-pid", str(os.getpid()), "--gpu-endpoint", endpoint, "--url", url,
        ], stdout=self.log, stderr=self.log)
        self.pending = bytearray()
        self.replies = {}
        self.events = []
        self.sequence = 0
        self.session = None
        try:
            self.wait(lambda: self.kernel.ConnectNamedPipe(self.pipe, None) or C.get_last_error() == 535,
                      "CEF control connection", pump=False)
        except BaseException:
            self.kernel.CloseHandle(self.pipe)
            self.process.terminate()
            self.process.wait(timeout=10)
            self.capture.close()
            self.log.close()
            raise
        client = W.ULONG()
        assert self.kernel.GetNamedPipeClientProcessId(self.pipe, C.byref(client)) and client.value == self.process.pid

    def pump(self):
        self.capture.receive()
        buffer = C.create_string_buffer(65536)
        count = W.DWORD()
        while self.kernel.ReadFile(self.pipe, buffer, len(buffer), C.byref(count), None) and count.value:
            self.pending.extend(buffer.raw[:count.value])
        while b"\0" in self.pending:
            raw, _, rest = self.pending.partition(b"\0")
            self.pending[:] = rest
            message = json.loads(raw)
            if "id" in message:
                self.replies[message["id"]] = message
            else:
                self.events.append(message)

    def wait(self, condition, description, seconds=30, pump=True):
        until = time.monotonic() + seconds
        while True:
            assert self.process.poll() is None, f"CEF exited: {self.process.returncode}; {description}"
            if pump:
                self.pump()
            result = condition()
            if result:
                return result
            assert time.monotonic() < until, f"Timed out: {description}; frame={self.capture.latest}"
            time.sleep(.005)

    def call(self, method, params=None, session=None, error=False, seconds=30):
        self.sequence += 1
        ident = self.sequence
        request = dict(id=ident, method=method, params=params or {})
        if session:
            request["sessionId"] = session
        data = json.dumps(request).encode() + b"\0"
        self.write(data)
        reply = self.wait(lambda: self.replies.pop(ident, None), method, seconds=seconds)
        if error:
            assert "error" in reply, reply
            return reply["error"]
        assert "error" not in reply, reply
        return reply["result"]

    def write(self, data):
        count = W.DWORD()
        assert self.kernel.WriteFile(self.pipe, data, len(data), C.byref(count), None) and count.value == len(data)

    def diagnostics(self, seconds=30):
        return self.call("Graffitty.diagnostics", seconds=seconds)

    def renderer_sandbox(self):
        """Inspect actual renderer tokens, not just the launcher's settings."""
        security = C.WinDLL("advapi32", use_last_error=True)
        self.kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        self.kernel.OpenProcess.restype = W.HANDLE
        security.OpenProcessToken.argtypes = [W.HANDLE, W.DWORD, C.POINTER(W.HANDLE)]
        security.OpenProcessToken.restype = W.BOOL
        security.IsTokenRestricted.argtypes = [W.HANDLE]
        security.IsTokenRestricted.restype = W.BOOL
        security.GetTokenInformation.argtypes = [W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.POINTER(W.DWORD)]
        security.GetTokenInformation.restype = W.BOOL
        security.GetSidSubAuthorityCount.argtypes = [C.c_void_p]
        security.GetSidSubAuthorityCount.restype = C.POINTER(C.c_ubyte)
        security.GetSidSubAuthority.argtypes = [C.c_void_p, W.DWORD]
        security.GetSidSubAuthority.restype = C.POINTER(W.DWORD)
        renderers = []
        for process in self.call("SystemInfo.getProcessInfo")["processInfo"]:
            if process["type"] != "renderer":
                continue
            handle = self.kernel.OpenProcess(0x1000, False, int(process["id"]))
            assert handle, C.WinError(C.get_last_error())
            token = W.HANDLE()
            try:
                assert security.OpenProcessToken(handle, 8, C.byref(token)), C.WinError(C.get_last_error())
                length = W.DWORD()
                security.GetTokenInformation(token, 25, None, 0, C.byref(length))
                data = C.create_string_buffer(length.value)
                assert security.GetTokenInformation(token, 25, data, len(data), C.byref(length)), C.WinError(C.get_last_error())
                sid = C.cast(data, C.POINTER(C.c_void_p))[0]
                count = security.GetSidSubAuthorityCount(sid)[0]
                integrity = security.GetSidSubAuthority(sid, count - 1)[0]
                restricted = bool(security.IsTokenRestricted(token))
                renderers.append(dict(pid=int(process["id"]), restricted=restricted, integrity=integrity))
                assert restricted and integrity <= 0x1000, f"Unsandboxed renderer: {renderers[-1]}"
            finally:
                if token:
                    self.kernel.CloseHandle(token)
                self.kernel.CloseHandle(handle)
        assert renderers, "No renderer process was inspected"
        return renderers

    def visible_windows(self):
        user = C.WinDLL("user32", use_last_error=True)
        callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
        user.EnumWindows.argtypes = [callback_type, W.LPARAM]
        user.EnumWindows.restype = W.BOOL
        user.IsWindowVisible.argtypes, user.IsWindowVisible.restype = [W.HWND], W.BOOL
        user.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
        user.GetWindowThreadProcessId.restype = W.DWORD
        windows = []
        @callback_type
        def inspect(window, _):
            process = W.DWORD()
            user.GetWindowThreadProcessId(window, C.byref(process))
            if process.value == self.process.pid and user.IsWindowVisible(window):
                windows.append(window)
            return True
        assert user.EnumWindows(inspect, 0)
        return windows

    def attach(self, target):
        self.session = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]

    def js(self, expression):
        result = self.call("Runtime.evaluate", {"expression": expression, "returnByValue": True, "userGesture": True}, self.session)
        assert "exceptionDetails" not in result, result
        return result["result"].get("value")

    def frame(self, color, size=(640, 480)):
        if self.backend == "chrome":
            # Chrome captures its native page viewport, excluding browser UI;
            # window minimum sizes and display DPI affect the physical pixels.
            size = tuple(self.js("[Math.ceil(innerWidth*devicePixelRatio),Math.ceil(innerHeight*devicePixelRatio)]"))
        self.wait(lambda: self.capture.latest and self.capture.latest[:2] == size
                  and self.capture.latest[2][3] == 255
                  and all(abs(a-b) < 5 for a, b in zip(self.capture.latest[2], color)), "captured page pixels")

    def close(self):
        try:
            if self.process.poll() is None:
                self.call("Browser.close")
                assert self.process.wait(timeout=20) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=10)
            self.kernel.CloseHandle(self.pipe)
            self.capture.close()
            self.log.close()


def run(args, backend, directory, base):
    print("START", backend, directory.name, flush=True)
    host = Host(args, backend, directory, base + "/red")
    try:
        # A cold DLL/profile initialization can be slow while CEF is linking on
        # the same machine. Navigation and frame deadlines stay at 30 seconds.
        host.diagnostics(seconds=180)
        print("READY", backend, flush=True)
        state = host.wait(lambda: (s if len((s := host.diagnostics()).get("pageTargets", [])) == 1 else None), "first page")
        assert state["backend"] == backend and state["windowless"] == (backend == "alloy"), state
        assert state["nativeWindowSupported"] == (backend == "chrome"), state
        red = state["pageTargets"][0]
        host.attach(red)
        host.wait(lambda: host.js("document.readyState === 'complete' && location.pathname === '/red'"), "loaded page")
        host.call("Graffitty.resize", dict(width=640, height=480))
        host.call("Graffitty.capture", dict(enabled=True))
        host.frame((208, 32, 32))
        sandbox = host.renderer_sandbox()
        (directory / "renderer-sandbox.json").write_text(json.dumps(sandbox, indent=2))
        print("FRAME", backend, host.capture.latest, flush=True)
        icon = host.wait(lambda: host.diagnostics()["pageDetails"][red].get("favicon"), "native favicon callback")
        assert icon.startswith("data:image/png;base64,") and base64.b64decode(icon.split(",", 1)[1]).startswith(b"\x89PNG"), icon
        details = host.diagnostics()["pageDetails"][red]
        assert details["title"] == "/red" and not details["loading"], details
        assert host.js("document.cookie='shared=yes; path=/';localStorage.setItem('shared','yes');true")
        before = time.monotonic()
        blue = host.call("Graffitty.createTab", dict(url=base + "/blue"))["targetId"]
        host.wait(lambda: host.diagnostics().get("nativeSelectedTargetId") == blue, "new tab selected")
        creation_ms = (time.monotonic() - before) * 1000
        host.attach(blue)
        host.wait(lambda: host.js("document.readyState === 'complete' && location.pathname === '/blue'"), "second page")
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Tabs must share browser storage"
        host.frame((32, 64, 208))
        print("SHARED_SESSION", backend, flush=True)
        before = time.monotonic()
        host.call("Graffitty.select", dict(targetId=red))
        host.frame((208, 32, 32))
        selection_ms = (time.monotonic() - before) * 1000
        host.call("Graffitty.moveTab", dict(targetId=blue, index=0))
        assert host.diagnostics()["pageTargets"] == [blue, red], "Native tab order must update"
        host.call("Target.closeTarget", dict(targetId=blue))
        host.wait(lambda: host.diagnostics()["pageTargets"] == [red], "closed tab removed")
        host.attach(red)
        assert host.js(f"window.open({json.dumps(base+'/green')},'_blank','width=300,height=200');true")
        green = host.wait(lambda: (target if (target := host.diagnostics().get("nativeSelectedTargetId")) and target != red else None), "popup selected")
        host.attach(green)
        host.wait(lambda: host.js("document.readyState === 'complete' && location.pathname === '/green'"), "popup loaded")
        assert host.js("window.opener.location.pathname") == "/red", "Popup must retain its opener"
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Popup must share browser storage"
        host.frame((32, 192, 64))
        print("POPUP", backend, flush=True)
        host.wait(lambda: host.diagnostics()["windowCount"] == (0 if backend == "alloy" else 1), "popup adopted without another window")
        assert host.diagnostics()["visibleWindows"] == 0, "Embedded browsing must not show a native window"
        if backend == "alloy":
            host.call("Graffitty.present", {"mode": "native"}, error=True)
        else:
            host.call("Graffitty.present", {"mode": "native"})
            host.wait(lambda: host.diagnostics()["nativeVisible"], "native window presentation")
            host.call("Graffitty.present", {"mode": "embedded"})
            host.wait(lambda: not host.diagnostics()["nativeVisible"], "return to embedded page")
            host.frame((32, 192, 64))
        host.call("Graffitty.zoom", {"direction": 1})
        host.call("Graffitty.zoom", {"direction": 0})
        # Invoke the real context-menu Inspect command, then check that DevTools
        # never becomes a Graffitty tab or replaces the captured page.
        host.events.clear()
        for kind in ["mousePressed", "mouseReleased"]:
            host.call("Input.dispatchMouseEvent", dict(type=kind, button="right", x=100, y=100,
                clickCount=1, contextMenuRequest="native-test"), host.session)
        menu = host.wait(lambda: next((e["params"] for e in host.events if e.get("method") == "Graffitty.contextMenu" and e["params"]["items"]), None), "context menu")
        def inspect(items):
            for item in items:
                if "inspect" in item.get("label", "").replace("&", "").lower(): return item["id"]
                nested = inspect(item.get("items", []))
                if nested is not None: return nested
        command = inspect(menu["items"])
        assert command is not None, menu
        host.call("Graffitty.contextMenuSelect", {"menu_id": menu["id"], "command_id": command})
        devtools = host.wait(lambda: next((t["targetId"] for t in host.call("Target.getTargets")["targetInfos"] if t["url"].startswith("devtools://")), None), "DevTools opened")
        host.wait(lambda: host.visible_windows(), "separate DevTools window visible")
        assert host.diagnostics()["pageTargets"] == [red, green], "DevTools must remain outside page tabs"
        assert host.js("document.body.style.background='#d02020';true")
        host.frame((208, 32, 32))
        print("INSPECT", backend, flush=True)
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Opening Inspect must preserve session storage"
        host.call("Target.closeTarget", {"targetId": devtools})
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Closing Inspect must preserve session storage"
        previous_size = host.capture.latest[:2]
        host.call("Graffitty.resize", {"width": 800, "height": 600})
        host.frame((208, 32, 32), (800, 600))
        assert host.capture.latest[:2] != previous_size, "Resize must update the captured viewport"
        # A static page must deliver its newest frame after receiver backpressure,
        # even when no subsequent animation causes another paint callback.
        host.capture.paused = True
        host.js("document.body.style.background='#20c040';true")
        time.sleep(.15)
        host.call("Graffitty.resize", {"width": 900, "height": 700})
        host.js("document.body.style.background='#d02020';true")
        time.sleep(.15)
        host.capture.paused = False
        host.frame((208, 32, 32), (900, 700))
        # The first Chrome page owns the native tab observer. Closing it must
        # establish a new observer without losing the remaining page/session.
        host.call("Target.closeTarget", {"targetId": red})
        host.wait(lambda: (s := host.diagnostics())["pageTargets"] == [green]
                  and s["tabBridgeReady"], "tab observer replaced after its owner closes")
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Closing the original tab must preserve session storage"
        replacement = host.call("Graffitty.createTab", {"url": base + "/blue"})["targetId"]
        host.attach(replacement)
        host.wait(lambda: host.js("document.readyState === 'complete' && location.pathname === '/blue'"), "replacement tab loaded")
        assert host.js("document.cookie.includes('shared=yes') && localStorage.getItem('shared')==='yes'"), "Replacement tab must retain browser storage"
        host.call("Target.closeTarget", {"targetId": replacement})
        host.wait(lambda: host.diagnostics()["pageTargets"] == [green], "replacement tab closed")
        host.attach(green)
        host.frame((208, 32, 32), (900, 700))
        targets = host.call("Target.getTargets")["targetInfos"]
        (directory / "targets.json").write_text(json.dumps(targets, indent=2))
        # Chromium may load its own component extensions. Graffitty must not
        # create or run the removed profile-local tab bridge.
        assert not (directory / "tab-extension").exists()
        assert not any(t["type"] == "service_worker" and t["url"].endswith("/bridge.js") for t in targets), targets
        result = dict(backend=backend, frames=host.capture.frames, creation_ms=round(creation_ms, 1),
                      selection_ms=round(selection_ms, 1), diagnostics=host.diagnostics())
        assert result["diagnostics"]["errors"] == 0, result["diagnostics"]
    except BaseException:
        if host.process.poll() is None:
            try:
                (directory / "failure.json").write_text(json.dumps(dict(
                    diagnostics=host.diagnostics(), frame=host.capture.latest,
                    viewport=host.js("[innerWidth,innerHeight,document.visibilityState]") if host.session else None,
                    storage=host.js("[location.href,document.cookie,localStorage.getItem('shared')]") if host.session else None), indent=2))
            except Exception as error:
                print("Could not collect failure diagnostics:", error, flush=True)
        raise
    finally:
        host.close()
    (directory / "result.json").write_text(json.dumps(result, indent=2))
    print("PASS", backend, "tabs, shared storage, ordering, popups, GPU pixels, presentation, Inspect, resize, backpressure and owner replacement", flush=True)
    print(json.dumps({k: v for k, v in result.items() if k != "diagnostics"}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--capture-library", type=Path, required=True)
    parser.add_argument("--backend", choices=["alloy", "chrome", "both"], default="both")
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "nt", "This test exercises Windows D3D and named pipes"
    args.artifacts.mkdir(parents=True, exist_ok=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Site) as web:
        threading.Thread(target=web.serve_forever, daemon=True).start()
        failures = 0
        try:
            for backend in ["alloy", "chrome"] if args.backend == "both" else [args.backend]:
                try:
                    run(args, backend, args.artifacts / (backend + "-" + uuid.uuid4().hex[:8]), f"http://127.0.0.1:{web.server_port}")
                except Exception:
                    failures += 1
                    traceback.print_exc()
        finally:
            web.shutdown()
        if failures:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
