#!/usr/bin/env python3
"""Real local IPC GPU media and terminal scene asset acceptance checks.

Run: python3 tests/support/local_media_e2e.py --evidence /tmp/local-media-evidence
See local_media_e2e.md for current implementation gaps and coverage limits.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests",)]
from e2e_server import PrivateServer
from terminal_scene_wire import Scenes


class LocalClient:
    """Observe every real IPC packet, including packets received during RPCs."""

    def __init__(self, descriptor, video=False):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(15)
        self.messages = []
        self.frames = []
        self.scenes = Scenes()
        self.sequence = 0
        local = descriptor["local"]
        assert local["url"].startswith("ipc://"), "Must exercise private IPC"
        self.socket.connect(local["url"][len("ipc://"):])
        self.send(dict(type="auth_local", version=1, token=local["token"],
                       workspace="main", features=[],
                       **({"chromium_video": ["hevc", "h264", "av1"]} if video else {})))
        self.until(lambda: any(m.get("type") == "ready" for m in self.messages))
        self.until(lambda: any(m.get("type") == "topology" for m in self.messages))
        self.topology = next(m for m in reversed(self.messages) if m.get("type") == "topology")

    def close(self):
        self.socket.close()

    def send(self, value):
        data = json.dumps(value).encode()
        self.socket.sendall(struct.pack("<BI", 1, len(data)) + data)

    def exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise EOFError("Local server disconnected")
            result.extend(chunk)
        return bytes(result)

    def receive(self):
        kind, size = struct.unpack("<BI", self.exact(5))
        assert size <= 8 * 1024 * 1024, f"Oversized IPC packet: {size}"
        data = self.exact(size)
        if kind == 1:
            self.messages.append(json.loads(data))
        else:
            assert kind == 2 and data[:4] == b"GRT2", "Invalid IPC framing"
            length = struct.unpack("<I", data[4:8])[0]
            assert length <= len(data) - 8
            header = json.loads(data[8:8 + length])
            if header.get("type") == "chromium" and "frame" in header:
                self.send(dict(type="chromium_ack", session=header["session"], frame=header["frame"]))
            payload = data[8 + length:]
            self.scenes.receive(header, payload, self.send)
            self.frames.append((header, payload))

    def until(self, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while not predicate():
            remaining = deadline - time.monotonic()
            assert remaining > 0, "Timed out waiting for real media delivery"
            self.socket.settimeout(remaining)
            self.receive()

    def action(self, kind, session=-1, **values):
        self.sequence += 1
        request = self.sequence
        self.send(dict(type=kind, session=session, request=request, **values))
        self.until(lambda: any(m.get("request") == request for m in self.messages))
        reply = next(m for m in self.messages if m.get("request") == request)
        assert reply["type"] == "ack", reply
        return reply.get("result")

    def subscribe(self, session):
        self.send(dict(type="subscribe", sessions=[session]))

    def terminal_bytes(self, pane):
        return bytes(self.scenes.text.get(pane, b""))

    def evidence(self):
        return {"messages": self.messages, "frames": [dict(header=header,
                payload_bytes=len(payload), payload_sha256=hashlib.sha256(payload).hexdigest())
                for header, payload in self.frames]}


PIXELS = bytes([255, 0, 0, 255, 0, 255, 0, 255,
                0, 0, 255, 255, 255, 255, 255, 255])


def fixture_png():
    """Generate a known 2x2 RGBA fixture without any image-decoder dependency."""
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0" + PIXELS[:8] + b"\0" + PIXELS[8:]))
            + chunk(b"IEND", b""))


def assert_scene_image(client, pane):
    client.until(lambda: client.scenes.image(pane, 9001) is not None)
    header, pixels = client.scenes.image(pane, 9001)
    assert (header["width"], header["height"]) == (2, 2)
    if header["format"] == "png":
        assert bytes(pixels) == fixture_png(), "Scene asset differs from the original PNG"
    else:
        assert header["format"] == "rgba" and bytes(pixels) == PIXELS
    assert any(p["image"] == 9001 for p in client.scenes.graphics[pane]["placements"])
    assert b"\x1b_G" not in client.terminal_bytes(pane), "Image escapes leaked into scene text"


def kitty_case(descriptor, directory, clients, reconnect=False, chunked=False):
    owner = LocalClient(descriptor)
    clients.append(owner)
    pane = owner.topology["panes"][0]["id"]
    owner.subscribe(pane)
    owner.until(lambda: any(h.get("type") == "terminal" for h, _ in owner.frames))
    owner.frames.clear()
    source = directory / "tty-graphics-protocol-local.png"
    source.write_bytes(fixture_png())
    path = base64.b64encode(os.fsencode(source)).decode()
    # t=t makes the server consume/delete the temporary source. The client
    # cannot pass by reopening the original file, including on reconnect.
    if chunked:
        encoded = base64.b64encode(fixture_png()).decode()
        first, last = encoded[:32], encoded[32:]
        source.unlink()  # Only the owner-decoded upload can seed reconnect.
        command = (f"printf '\\033_Ga=T,t=d,f=100,i=9001,p=1,c=2,r=2,q=2,m=1;{first}\\033\\\\'; "
                   "sleep 0.05; "
                   f"printf '\\033_Gm=0,q=2;{last}\\033\\\\'; "
                   "printf 'LOCAL_MEDIA_%s\\n' READY\n")
    else:
        command = (f"printf '\\033_Ga=T,t=t,f=100,i=9001,p=1,c=2,r=2,q=2;{path}\\033\\\\'; "
                   "printf 'LOCAL_MEDIA_%s\\n' READY\n")
    owner.action("text", pane, text=command)
    owner.until(lambda: b"LOCAL_MEDIA_READY" in owner.terminal_bytes(pane))
    (directory / "live-terminal.bin").write_bytes(owner.terminal_bytes(pane))
    assert not source.exists(), "Server did not consume the Kitty temporary-file upload"
    client = owner
    if reconnect:
        owner.close()
        client = LocalClient(descriptor)
        clients.append(client)
        assert client.topology["panes"][0]["id"] == pane
        client.subscribe(pane)
        client.until(lambda: b"LOCAL_MEDIA_READY" in client.terminal_bytes(pane))
        assert any(h.get("scene", {}).get("snapshot") for h, _ in client.frames), "Reconnect did not deliver a checkpoint"
    stream = client.terminal_bytes(pane)
    (directory / "terminal.bin").write_bytes(stream)
    assert_scene_image(client, pane)


def chromium_case(descriptor, directory, clients, video=False, fail_import=False, relay=False, release=False):
    from conformance.local_gpu_probe import NativeGpu
    native = NativeGpu(directory)
    checks = {"production_native_source_sha256": native.source_sha256, "frames": []}
    expected = bytes([0, 0, 0, 255])  # BGRA sampled by a real Metal blit
    relay_process = None
    relay_directory = None
    import http.server
    import threading
    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body=b"<html><body style='margin:0;background:linear-gradient(to right,black 50%,white 50%)'></body></html>"
            self.send_response(200);self.send_header("Content-Type","text/html")
            self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*args):pass
    http=http.server.ThreadingHTTPServer(("127.0.0.1",0),Fixture)
    threading.Thread(target=http.serve_forever,daemon=True).start()
    try:
        connection_descriptor = descriptor
        if relay:
            import subprocess
            # Darwin AF_UNIX names cannot include a long evidence path.
            relay_directory = tempfile.TemporaryDirectory(prefix="gft-relay-", dir="/tmp")
            relay_path = Path(relay_directory.name) / "relay.sock"
            relay_process = subprocess.Popen([sys.executable, str(ROOT / "tests/conformance/unix_byte_relay.py"),
                str(relay_path), descriptor["local"]["url"][len("ipc://"):]])
            deadline=time.monotonic()+5
            while not relay_path.exists():
                assert time.monotonic()<deadline and relay_process.poll() is None
                time.sleep(.01)
            connection_descriptor=json.loads(json.dumps(descriptor))
            connection_descriptor["local"]["url"]="ipc://"+str(relay_path)
        client = LocalClient(connection_descriptor, video=video or fail_import or relay or release)
        clients.append(client)
        pane = client.topology["panes"][0]["id"]
        chromium = client.action("rpc", pane, method="chromium.create", params={"url": f"http://127.0.0.1:{http.server_port}/"})
        bid = int(chromium["chromium"][1:])

        def gpu_frame(receiver, connection, predicate, timeout=20):
            # Use the kernel peer PID, never the server descriptor's claimed PID.
            peer_pid = struct.unpack("i", connection.socket.getsockopt(0, 2, 4))[0]
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                import select
                while select.select([connection.socket],[],[],0)[0]:connection.receive()
                frame=receiver.poll(peer_pid)
                if frame and predicate(frame):return frame
                if frame:frame.close()
                time.sleep(.005)
            raise AssertionError("No verified native GPU frame arrived")

        def negotiate(connection, receiver):
            connection.action("chromium_gpu_offer", bid, mechanism="mach-iosurface-v1", endpoint=receiver.endpoint)
            probe=gpu_frame(receiver,connection,lambda frame:frame.probe)
            probe.prove(fail_import=fail_import)
            if fail_import:
                result=connection.action("chromium_gpu_confirm",bid)
                assert not result["active"],"Failed GPU import activated native sharing"
                return False
            result=connection.action("chromium_gpu_confirm",bid)
            assert result["active"], result
            probe.close()
            return True

        receiver=native.receiver()
        if relay:
            try:
                negotiate(client,receiver)
            except AssertionError as error:
                assert "sender differs from socket peer" in str(error), error
                checks["relay_rejected_by_kernel_peer_identity"]=True
            else:raise AssertionError("Byte forwarding incorrectly negotiated native GPU sharing")
        else:negotiate(client,receiver)

        if release:
            client.subscribe(bid)
            gpu_frame(receiver,client,lambda f:not f.probe and f.sample(f.width//4,f.height//2)==expected and f.sample(f.width*3//4,f.height//2)==bytes([255,255,255,255]))
            receiver.close()
            client.action("rpc",pane,method="chromium.command",params={"chromium":chromium["chromium"],"action":"resize","args":{"width":804,"height":604}})
            client.until(lambda:any(m.get("type")=="chromium_gpu_state" and m.get("session")==bid and m.get("active") is False for m in client.messages))
            checks["released_destination_resumes_video"]=True
        if fail_import or relay or release:
            client.action("chromium_gpu_reject",bid)
            client.subscribe(bid)
            client.until(lambda:any(h.get("type")=="chromium" and h.get("session")==bid and h.get("key") for h,_ in client.frames))
            header,payload=next((h,p) for h,p in client.frames if h.get("type")=="chromium" and h.get("session")==bid and h.get("key"))
            assert header["format"] in ("hevc","h264","av1"),header
            width,height,pixels=native.decode_video(header,payload)
            assert (width,height)==(header["width"],header["height"])
            offset=(height//2*width+width//4)*4
            assert all(abs(a-b)<=4 for a,b in zip(pixels[offset:offset+4],bytes([0,0,0,255]))),pixels[offset:offset+4]
            checks["fallback"]={"format":header["format"],"decoded_dimensions":[width,height],"rgba_sample":list(pixels[offset:offset+4])}
            return

        client.subscribe(bid)
        frame=gpu_frame(receiver,client,lambda f:not f.probe and f.sample(f.width//4,f.height//2)==expected and f.sample(f.width*3//4,f.height//2)==bytes([255,255,255,255]))
        checks["frames"].append({"width":frame.width,"height":frame.height,"sequence":frame.sequence,"bgra":list(frame.sample())})
        original=frame
        client.action("rpc",pane,method="chromium.command",params={"chromium":chromium["chromium"],"action":"resize","args":{"width":802,"height":602}})
        frame=gpu_frame(receiver,client,lambda f:not f.probe and (f.width,f.height)==(802,602) and f.sample(200,300)==expected and f.sample(600,300)==bytes([255,255,255,255]))
        assert original.sample()==expected,"Previous imported resource was reused during resize"
        checks["frames"].append({"width":frame.width,"height":frame.height,"sequence":frame.sequence,"bgra":list(frame.sample())})
        client.close()
        assert frame.sample()==expected,"Disconnect invalidated retained GPU resource"
        receiver.close()
        # A new socket cannot reuse an old probe; it must exchange a fresh right.
        client=LocalClient(descriptor,video=video);clients.append(client)
        try:client.action("chromium_gpu_confirm",bid)
        except AssertionError:pass
        else:raise AssertionError("Reconnect reused a previous native GPU proof")
        receiver=native.receiver();negotiate(client,receiver);client.subscribe(bid)
        frame=gpu_frame(receiver,client,lambda f:not f.probe and (f.width,f.height)==(802,602) and f.sample(200,300)==expected and f.sample(600,300)==bytes([255,255,255,255]))
        checks["reconnected"]=True
        assert not any(h.get("type")=="chromium" for connection in clients for h,_ in connection.frames),"Native local chromium also received encoded frames"
    finally:
        (directory / "native-gpu.json").write_text(json.dumps(checks,indent=2)+"\n")
        native.close()
        http.shutdown();http.server_close()
        if relay_process:
            relay_process.terminate();relay_process.wait(timeout=5)
        if relay_directory: relay_directory.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=ROOT / "target/debug/gft")
    parser.add_argument("--case", choices=["all", "chromium", "kitty"], default="all")
    parser.add_argument("--backend", choices=["chrome", "alloy"], default="chrome")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    server_binary = args.server.resolve()
    digest = hashlib.sha256(server_binary.read_bytes()).hexdigest()
    cases = []
    if args.case in ("all", "chromium"):
        cases += [("chromium-default", lambda d, p, c: chromium_case(d, p, c)),
                  ("chromium-video-capable", lambda d, p, c: chromium_case(d, p, c, video=True)),
                  ("chromium-import-fallback", lambda d,p,c: chromium_case(d,p,c,fail_import=True)),
                  ("chromium-released-resource-fallback", lambda d,p,c: chromium_case(d,p,c,release=True)),
                  ("chromium-unix-relay-fallback", lambda d,p,c: chromium_case(d,p,c,relay=True))]
    if args.case in ("all", "kitty"):
        cases += [("kitty-live", lambda d, p, c: kitty_case(d, p, c)),
                  ("kitty-reconnect", lambda d, p, c: kitty_case(d, p, c, reconnect=True)),
                  ("kitty-chunked-live", lambda d, p, c: kitty_case(d, p, c, chunked=True)),
                  ("kitty-chunked-reconnect", lambda d, p, c: kitty_case(d, p, c, reconnect=True, chunked=True))]
    results = []
    # PrivateServer resolves its explicit binary from this environment variable.
    os.environ["GRAFFITTY_TEST_SERVER"] = str(server_binary)
    for name, run in cases:
        directory = evidence / name
        directory.mkdir()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("GRAFFITTY_",))}
        if os.environ.get("GRAFFITTY_CHROMIUM_HOST"):
            env["GRAFFITTY_CHROMIUM_HOST"] = os.environ["GRAFFITTY_CHROMIUM_HOST"]
        env["GRAFFITTY_SERVER__CHROMIUM__BACKEND"] = args.backend
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
        if name.startswith("kitty-"):
            # Ghostty only accepts t=t uploads beneath its configured temp dir.
            env["TMPDIR"] = str(directory)
        clients = []
        result = {"case": name, "status": "FAIL"}
        try:
            with PrivateServer(env, directory, "/bin/sh") as server:
                try:
                    descriptor = json.loads(server.descriptor.read_text())
                    assert descriptor.get("remote") is None, "Local tests must not open network access"
                    run(descriptor, directory, clients)
                    result["status"] = "PASS"
                finally:
                    for index, client in enumerate(clients):
                        (directory / f"client-{index}.json").write_text(
                            json.dumps(client.evidence(), indent=2) + "\n")
                        client.close()
        except Exception as error:
            result["error"] = f"{type(error).__name__}: {error}"
        results.append(result)
        print(json.dumps(result), flush=True)
    unchanged = hashlib.sha256(server_binary.read_bytes()).hexdigest() == digest
    passed = unchanged and all(r["status"] == "PASS" for r in results)
    (evidence / "report.json").write_text(json.dumps(dict(
        status="PASS" if passed else "FAIL", backend=args.backend, server=str(server_binary),
        server_sha256=digest, binary_unchanged=unchanged, cases=results), indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
