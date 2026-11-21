# /// script
# dependencies = ["websocket-client>=1.8,<2", "pillow>=11,<13"]
# ///
"""Measure image delivery from the PTY through the VT to the subscriber.

    mise exec -- cargo build --release -p graffitty-cli
    mise exec -- uv run tests/server/session_image_latency.py --output /tmp/gr-images

Each timed upload uses fresh pixels to bypass the server's PNG decode cache.
Reconnect timings include scene assembly and requested assets. The benchmark
excludes authentication and GUI rendering.
"""
import argparse
import base64
import io
import json
import os
from pathlib import Path
import platform
import random
import socket
import statistics
import struct
import subprocess
import sys
import time

from PIL import Image, ImageDraw
import websocket
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from terminal_scene_wire import Scenes

ROOT = Path(__file__).resolve().parents[2]
CASES = [("icon", 256, False), ("diagram", 1024, False),
         ("noise", 1024, True), ("noise", 2048, True)]


def stats(values):
    ordered = sorted(values)
    return dict(median_ms=round(statistics.median(values), 3),
                max_ms=round(max(values), 3), samples=len(values))


class Wire:
    def __init__(self, descriptor, route):
        self.route = route
        self.scenes = Scenes()
        if route == "ipc":
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.settimeout(60)
            self.socket.connect(descriptor["local"]["url"].removeprefix("ipc://"))
        else:
            self.socket = websocket.create_connection(descriptor["remote"]["url"], timeout=60)
        # A loopback WebSocket also presents the local capability.
        self.send(dict(type="auth_local", version=1, workspace="main",
                       token=descriptor["local"]["token"], features=[]))
        while True:
            value, _ = self.receive()
            if value.get("type") == "topology":
                self.pane = value["panes"][0]["id"]
                break

    def send(self, value):
        data = json.dumps(value).encode()
        if self.route == "ipc":
            self.socket.sendall(b"\x01" + struct.pack("<I", len(data)) + data)
        else:
            self.socket.send(data.decode())

    def exact(self, size):
        parts = bytearray(size)
        view = memoryview(parts)
        offset = 0
        while offset < size:
            count = self.socket.recv_into(view[offset:])
            if not count:
                raise EOFError("Server disconnected")
            offset += count
        return parts

    def receive(self):
        if self.route == "ipc":
            kind, size = struct.unpack("<BI", self.exact(5))
            assert size <= 8*1024*1024
            data = self.exact(size)
            binary = kind == 2
        else:
            data = self.socket.recv()
            binary = isinstance(data, bytes)
        if not binary:
            message = json.loads(data)
            assert message.get("type") != "error", message
            return message, b""
        assert data[:4] == b"GRT2"
        size = struct.unpack("<I", data[4:8])[0]
        return json.loads(data[8:8+size]), data[8+size:]

    def collect(self, marker, image_id=None):
        wire_bytes = resets = 0
        while True:
            header, payload = self.receive()
            self.scenes.receive(header, payload, self.send)
            wire_bytes += len(payload)
            tx = header.get("scene", {})
            resets += int(tx.get("snapshot", False) and tx.get("offset") == 0)
            text = self.scenes.text.get(self.pane, b"")
            asset = self.scenes.image(self.pane, image_id) if image_id is not None else None
            if marker in text and (image_id is None or asset is not None):
                return bytes(text), wire_bytes, resets, asset

    def close(self):
        self.socket.close()


def fixture(side, noisy, seed):
    if noisy:
        # Deliberately poorly compressible, a bound rather than a typical photo.
        image = Image.frombytes("RGB", (side, side), random.Random(seed).randbytes(side*side*3))
    else:
        image = Image.new("RGB", (side, side), (24, 28, 37))
        draw = ImageDraw.Draw(image)
        for y in range(16, side-16, 28):
            draw.rectangle((16, y, side-16, y+12), fill=((y+seed*11)%255, 120, 190))
            draw.text((24, y), f"row {y} sample {seed}", fill="white")
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def kitty(png, path, medium):
    if medium == "file":
        return b"\x1b_Ga=T,t=f,f=100,i=91,p=1,c=20,r=10,C=1,q=2;" + base64.b64encode(os.fsencode(path)) + b"\x1b\\"
    encoded = base64.b64encode(png)
    chunks = []
    for i in range(0, len(encoded), 4096):
        more = int(i+4096 < len(encoded))
        head = "a=T,t=d,f=100,i=91,p=1,c=20,r=10,C=1,q=2," if i == 0 else "q=2,"
        chunks.append(f"\x1b_G{head}m={more};".encode() + encoded[i:i+4096] + b"\x1b\\")
    return b"".join(chunks)


def verify_original_png(asset, png):
    """The requested scene asset preserves the original PNG without re-encoding."""
    assert asset is not None
    header, payload = asset
    assert header["format"] == "png" and bytes(payload) == png


def run_case(args, case, route, medium):
    name, side, noisy = case
    key = f"{name}-{side}-{route}-{medium}"
    root = args.output / key
    root.mkdir(exist_ok=True)
    program = root / "writer.py"
    program.write_text(f"#!{sys.executable}\n"
                       "import os, sys, tty\nfrom pathlib import Path\n"
                       "tty.setraw(0)\nos.write(1,b'BENCH_READY')\n"
                       "for line in sys.stdin.buffer:\n"
                       "    data = memoryview(Path(line.decode().strip()).read_bytes())\n"
                       "    while data:\n"
                       "        data = data[os.write(1, data):]\n")
    program.chmod(0o700)
    descriptor_path = root / "connection.json"
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
               XDG_STATE_HOME=str(root / "state"))
    with (root / "server.log").open("w") as log:
        server = subprocess.Popen([args.server, "server", "--listen", "127.0.0.1:0", "--connection", descriptor_path,
                                   "--shell", program], env=env, stdout=log, stderr=log)
    client = None
    try:
        for _ in range(200):
            if descriptor_path.exists():
                break
            assert server.poll() is None, (root / "server.log").read_text()
            time.sleep(.025)
        descriptor = json.loads(descriptor_path.read_text())
        client = Wire(descriptor, route)
        client.send(dict(type="subscribe", sessions=[client.pane]))
        client.collect(b"BENCH_READY")
        upload_ms, reconnect_ms = [], []
        sent, received = [], []
        for n in range(args.samples):
            png = fixture(side, noisy, n)
            image_path = root / "image.png"
            image_path.write_bytes(png)
            marker = f"DONE_{n:05d}".encode()
            output = b"\x1b[2J\x1b[H\x1b_Ga=d,d=A,q=2\x1b\\" + kitty(png, image_path, medium) + b"\r\n" + marker
            transfer = root / "output.vt"
            transfer.write_bytes(output)
            start = time.perf_counter_ns()
            client.send(dict(type="text", session=client.pane, text=str(transfer)+"\n"))
            payload, count, resets, asset = client.collect(marker, 91)
            upload_ms.append((time.perf_counter_ns()-start)/1e6)
            verify_original_png(asset, png)
            sent.append(len(png))
            received.append(count)
            if n == args.samples-1 and route == "ipc":
                (root / "received.vt").write_bytes(payload)
            client.close()
            client = Wire(descriptor, route)
            start = time.perf_counter_ns()
            client.send(dict(type="subscribe", sessions=[client.pane]))
            payload, _, resets, asset = client.collect(marker, 91)
            reconnect_ms.append((time.perf_counter_ns()-start)/1e6)
            assert resets == 1
            verify_original_png(asset, png)
            if n == args.samples-1 and route == "ipc":
                (root / "reconnect.vt").write_bytes(payload)
            # No stale terminal packets can match the next iteration's marker.
        if route != "ipc":
            image_path.unlink()
            transfer.unlink()
        return dict(case=key, side=side, input=medium, transport=route,
                    png_bytes=int(statistics.median(sent)),
                    subscriber_bytes=int(statistics.median(received)),
                    fresh_upload=stats(upload_ms), reconnect=stats(reconnect_ms))
    finally:
        if client:
            client.close()
        server.terminate()
        server.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=ROOT / "target/release/gft")
    parser.add_argument("--samples", type=int, default=7)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    result = dict(platform=platform.platform(), server=str(args.server),
                  excludes="Client VT decoding, Godot rendering and display; Python subscriber overhead is included.",
                  rows=[])
    for case in CASES:
        for route in ["ipc", "websocket"]:
            for medium in ["inline", "file"]:
                row = run_case(args, case, route, medium)
                result["rows"].append(row)
                print(json.dumps(row), flush=True)
                (args.output / "results.json").write_text(json.dumps(result, indent=2)+"\n")


if __name__ == "__main__":
    main()
