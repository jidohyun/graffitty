"""Exercise the real owner protocol, including demand-driven image resources.

Run after cargo build -p graffitty-cli. Set GRAFFITTY_TEST_SERVER to select
a release binary. Each test owns its isolated descriptor, shell and storage.
"""
import base64
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
SERVER = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/debug/gft"))
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from private_session_e2e import local_socket


def png(side=64, red=240):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes((red, 30, 50, 255)) * side) * side)) + chunk(b"IEND", b""))


class Peer:
    def __init__(self, descriptor, flow=False, network=False):
        self.metadata = {}
        self.network = network
        self.buffer = bytearray()
        if network:
            import websocket
            self.socket = websocket.create_connection(descriptor["url"], timeout=15)
        else:
            self.socket = local_socket(descriptor["local"]["url"], timeout=15)
        # Loopback WebSockets present the local capability, like private IPC.
        self.send(type="auth_local", version=1, token=descriptor["local"]["token"],
                  workspace="main", features=(["scene-flow-v1"] if flow else []))
        while True:
            header, _ = self.read()
            if header.get("type") == "topology":
                self.id = header["panes"][0]["id"]
                break
        self.send(type="subscribe", sessions=[self.id])

    def send(self, **message):
        data = json.dumps(message).encode()
        if self.network:
            self.socket.send(data.decode())
        else:
            self.socket.sendall(b"\1" + struct.pack("<I", len(data)) + data)

    def exact(self, size):
        if self.network:
            import websocket
            while len(self.buffer) < size:
                try:
                    packet = self.socket.recv()
                except websocket.WebSocketTimeoutException as error:
                    raise socket.timeout() from error
                kind = 1 if isinstance(packet, str) else 2
                if kind == 1: packet = packet.encode()
                self.buffer.extend(struct.pack("<BI", kind, len(packet)) + packet)
            data = self.buffer[:size]
            del self.buffer[:size]
            return data
        data = bytearray()
        while len(data) < size:
            chunk = self.socket.recv(size - len(data))
            if not chunk:
                raise EOFError("Owner disconnected")
            data.extend(chunk)
        return data

    def read(self):
        kind, size = struct.unpack("<BI", self.exact(5))
        data = self.exact(size)
        if kind == 1:
            return json.loads(data), b""
        assert data[:4] == b"GRT2"
        length = struct.unpack("<I", data[4:8])[0]
        header, payload = json.loads(data[8:8 + length]), bytes(data[8 + length:])
        tx = header.get("scene", {})
        if tx.get("graphics_bytes", 0):
            boundary = max(0, tx["total"] - tx["graphics_bytes"] - tx["offset"])
            key = (header["session"], tx["revision"])
            self.metadata.setdefault(key, bytearray()).extend(payload[boundary:])
            payload = payload[:boundary]
            if tx["commit"]:
                tx["graphics"] = json.loads(self.metadata.pop(key))
        return header, payload

    def until(self, marker):
        text = bytearray()
        packets = []
        while True:
            header, data = self.read()
            packets.append((header, data))
            if header.get("type") == "terminal":
                text.extend(data)
                if marker in text and header["scene"]["commit"]:
                    return packets


class Owner:
    def __init__(self, network=False):
        self.network = network

    def __enter__(self):
        evidence = os.environ.get("GRAFFITTY_SCENE_EVIDENCE")
        if evidence:
            Path(evidence).mkdir(parents=True, exist_ok=True)
        self.tmp = None if evidence else tempfile.TemporaryDirectory(prefix="graffitty-scene-")
        self.path = Path(tempfile.mkdtemp(prefix="scene-", dir=evidence)) if evidence else Path(self.tmp.name)
        writer = self.path / "writer.py"
        setup = "import tty\ntty.setraw(0)\n"
        if os.name == "nt":
            setup = """import ctypes,msvcrt
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.GetStdHandle.restype=ctypes.c_void_p
k.GetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
k.SetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
for number,fd in [(-10,0),(-11,1)]:
 h=k.GetStdHandle(number); mode=ctypes.c_ulong()
 assert k.GetConsoleMode(h,ctypes.byref(mode))
 assert k.SetConsoleMode(h,(mode.value & ~7) | 0x200 if fd==0 else mode.value | 4)
 msvcrt.setmode(fd,os.O_BINARY)
"""
        writer.write_text("#!" + sys.executable + "\nimport os,sys,time\nfrom pathlib import Path\n" + setup + "os.write(1,b'@@READY@@')\nfor line in sys.stdin:\n if line.strip() == '--exit--': break\n data=Path(line.strip()).read_bytes()\n view=memoryview(data)\n while view: view=view[os.write(1,view):]\n", encoding="utf-8")
        writer.chmod(0o700)
        self.descriptor = self.path / "connection.json"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(self.path / kind.lower())
        self.log = (self.path / "server.log").open("w")
        shell_args = ["--shell", writer]
        if os.name == "nt":
            config = self.path / "config/graffitty/server.toml"
            config.parent.mkdir(parents=True)
            config.write_text("[terminal]\nshell=" + json.dumps([sys._base_executable, str(writer)]) + "\nlogin_shell=false\nshell_integration=false\n", encoding="utf-8")
            shell_args = []
        self.process = subprocess.Popen([SERVER, "server", "--connection", self.descriptor, *shell_args, "--auth-file", self.path / "auth.json"] + (["--listen", "127.0.0.1:0"] if self.network else []), env=env, stdout=self.log, stderr=self.log)
        for _ in range(800):
            if self.descriptor.exists():
                break
            if self.process.poll() is not None:
                raise RuntimeError((self.path / "server.log").read_text())
            time.sleep(.025)
        try:
            self.peer = Peer(json.loads(self.descriptor.read_text()))
            self.peer.until(b"@@READY@@")
        except BaseException:
            self.process.terminate()
            self.process.wait(timeout=10)
            self.log.close()
            if self.tmp: self.tmp.cleanup()
            raise
        self.sequence = 0
        return self

    def output(self, data):
        self.sequence += 1
        marker = f"@@DONE_{self.sequence}@@".encode()
        source = self.path / f"output-{self.sequence}.vt"
        source.write_bytes(data + marker)
        self.peer.send(type="text", session=self.peer.id, text=str(source) + "\n")
        return self.peer.until(marker)

    def upload(self, image_id=91, side=64, virtual=False, red=240):
        image = self.path / f"image-{image_id}.png"
        image.write_bytes(png(side, red))
        command = f"\x1b_Ga=T,t=f,f=100,i={image_id},p=1,c=20,r=10,C=1,U={int(virtual)},q=2;".encode() + base64.b64encode(os.fsencode(image)) + b"\x1b\\"
        return self.output(command)

    def __exit__(self, *_):
        self.peer.socket.close()
        self.process.terminate()
        self.process.wait(timeout=10)
        self.log.close()
        if self.tmp: self.tmp.cleanup()


@unittest.skipUnless(SERVER.exists(), "Build native server first")
class TerminalSceneTests(unittest.TestCase):
    def test_consumed_png_delivers_raw_local_pixels_and_compressed_network_pixels(self):
        with Owner(network=True) as owner:
            previous_key = None
            for red in (137, 43):
                # Kitty temporary-file uploads must live in the OS temporary
                # directory; arbitrary owner fixture paths are rejected.
                descriptor_fd, source_name = tempfile.mkstemp(prefix="tty-graphics-protocol-", suffix=".png")
                os.close(descriptor_fd)
                source = Path(source_name)
                source.write_bytes(png(129, red))
                packets = owner.output(b"\x1b_Ga=T,t=t,f=100,i=91,p=1,c=20,r=10,C=1,q=2;"
                                       + base64.b64encode(os.fsencode(source)) + b"\x1b\\")
                self.assertFalse(source.exists())
                header = next(h for h, _ in packets if h.get("scene", {}).get("graphics", {}).get("images"))
                key = header["scene"]["graphics"]["images"][0]["asset"]
                self.assertNotEqual(key, previous_key)
                previous_key = key
                descriptor = json.loads(owner.descriptor.read_text())
                for transport in ("live", "fresh-local", "network"):
                    peer = owner.peer if transport == "live" else Peer(descriptor, network=transport == "network")
                    try:
                        peer.send(type="terminal_asset_request", session=peer.id, asset=key, request=111)
                        received = bytearray()
                        while True:
                            header, data = peer.read()
                            if header.get("type") != "terminal_asset": continue
                            asset = header["asset"]
                            self.assertEqual(asset["asset"], key)
                            self.assertEqual((asset["width"], asset["height"]), (129, 129))
                            self.assertEqual(asset["offset"], len(received))
                            self.assertEqual(asset["format"], "png" if transport == "network" else "rgba")
                            received.extend(data)
                            if len(received) == asset["total"]: break
                        self.assertEqual(received, png(129, red) if transport == "network"
                                         else bytes((red, 30, 50, 255)) * (129 * 129))
                    finally:
                        if peer is not owner.peer: peer.socket.close()

    def test_snapshot_larger_than_credit_window_finishes(self):
        with Owner() as owner:
            owner.peer.send(type="resize", session=owner.peer.id, columns=500, rows=300)
            owner.output((b"X" * 499 + b"\r\n") * 299 + b"LARGE_SNAPSHOT_END")
            slow = Peer(json.loads(owner.descriptor.read_text()), flow=True)
            try:
                offset = 0
                chunks = 0
                while True:
                    header, payload = slow.read()
                    if "scene" not in header: continue
                    tx = header["scene"]
                    self.assertTrue(tx["snapshot"])
                    self.assertEqual(tx["offset"], offset)
                    # Peer strips the final graphics metadata from text.
                    offset += len(payload) + (tx["graphics_bytes"] if tx["commit"] else 0)
                    chunks += 1
                    slow.send(type="scene_ack", sequence=header["flow"])
                    if tx["commit"]:
                        self.assertEqual(offset, tx["total"])
                        self.assertIn(b"LARGE_SNAPSHOT_END", payload)
                        break
                self.assertGreater(chunks, 2)
            finally:
                slow.socket.close()

    def test_slow_reader_keeps_small_deltas_and_input(self):
        self._slow_reader_backlog_and_input(large=False)

    def test_slow_reader_coalesces_large_redraws_and_input(self):
        self._slow_reader_backlog_and_input(large=True)

    def _slow_reader_backlog_and_input(self, large):
        with Owner(network=True) as owner:
            slow = Peer(json.loads(owner.descriptor.read_text()), flow=True, network=True)
            try:
                # Consume the initial snapshot without returning credit.
                first = []
                while not first or not first[-1][0].get("scene", {}).get("commit"):
                    first.append(slow.read())
                # Fill the small-packet window without returning credit.
                for _ in range(7): owner.output(b"OLD_FRAME")
                # A forged future ACK must not release any credit.
                slow.send(type="scene_ack", sequence=999999)
                for n in range(5):
                    owner.output(b"\x1b[2J" + ((b"\x1b[H" + b"x" * 70) * 1000 if large else b"")
                                 + b"\x1b[H" + f"NEW_FRAME_{n}".encode())
                time.sleep(.6)
                slow.socket.settimeout(.15)
                queued = first[:]
                while True:
                    try:
                        queued.append(slow.read())
                    except socket.timeout:
                        break
                packets = [h for h, _ in queued if "flow" in h]
                self.assertLessEqual(len(packets), 8)
                self.assertLessEqual(sum(len(p) for h, p in queued), 128 * 1024)
                self.assertTrue(packets)
                slow.socket.settimeout(10)
                slow.send(type="scene_ack", sequence=max(h["flow"] for h in packets))
                latest = slow.until(b"NEW_FRAME_4")
                self.assertEqual(any(h.get("scene", {}).get("snapshot") for h, _ in latest), large)
                slow.send(type="scene_ack", sequence=max(h.get("flow", 0) for h, _ in latest))
                # Input still reaches the same shell while presentation is stalled.
                source = owner.path / "slow-input.vt"
                source.write_bytes(b"INPUT_EXACTLY_ONCE")
                slow.send(type="text", session=slow.id, text=str(source) + "\n")
                applied = slow.until(b"INPUT_EXACTLY_ONCE")
                text = b"".join(p for _, p in applied)
                self.assertEqual(text.count(b"INPUT_EXACTLY_ONCE"), 1)
            finally:
                slow.socket.close()

    def test_erase_does_not_reset_or_transfer_retained_pixels(self):
        with Owner() as owner:
            for i in range(6):
                owner.upload(90 + i, side=2048, virtual=True)
            started = time.perf_counter()
            packets = owner.output(b"\x1b[24;1H\x1b[2K")
            elapsed = time.perf_counter() - started
            self.assertTrue(all(h.get("type") != "terminal_asset" for h, _ in packets))
            terminals = [(h, p) for h, p in packets if h.get("type") == "terminal"]
            self.assertTrue(all(not h["scene"]["snapshot"] for h, _ in terminals))
            self.assertLess(sum(len(p) for _, p in terminals), 100)
            print(f"six retained 2048px images: erase {sum(len(p) for _, p in terminals)} bytes, {elapsed * 1000:.2f} ms", flush=True)

    def test_asset_is_requested_once_and_identity_survives_placement_changes(self):
        with Owner() as owner:
            packets = owner.upload()
            header = next(h for h, _ in packets if h.get("scene", {}).get("graphics"))
            key = header["scene"]["graphics"]["images"][0]["asset"]
            self.assertTrue(all(b"\x1b_G" not in p for _, p in packets))
            owner.peer.send(type="terminal_asset_request", session=owner.peer.id, asset=key, request=111)
            received = bytearray()
            ack = False
            while True:
                h, data = owner.peer.read()
                ack |= h.get("request") == 111 and h.get("type") == "ack"
                if h.get("type") == "terminal_asset":
                    asset = h["asset"]
                    self.assertEqual(asset["format"], "rgba")
                    self.assertEqual(asset["offset"], len(received))
                    self.assertEqual(asset["asset"], key)
                    received.extend(data)
                    if len(received) == asset["total"]:
                        break
            self.assertTrue(ack)
            self.assertEqual(received, bytes((240, 30, 50, 255)) * (64 * 64))
            packets = owner.output(b"\x1b_Ga=d,d=a,q=2;\x1b\\")
            state = next(h["scene"]["graphics"] for h, _ in packets if h.get("scene", {}).get("graphics") is not None)
            self.assertEqual(state["placements"], [])
            packets = owner.output(b"\x1b[1;1H\x1b_Ga=p,i=91,p=2,c=4,r=2,C=1,q=2;\x1b\\")
            state = next(h["scene"]["graphics"] for h, _ in packets if h.get("scene", {}).get("graphics"))
            self.assertEqual(state["images"][0]["asset"], key)
            self.assertTrue(all(h.get("type") != "terminal_asset" for h, _ in packets))
            changed = owner.upload(red=20)
            state = next(h["scene"]["graphics"] for h, _ in changed if h.get("scene", {}).get("graphics"))
            self.assertNotEqual(state["images"][0]["asset"], key)

    def test_sixel_erase_updates_placement_without_replaying_pixels(self):
        with Owner() as owner:
            owner.output(b"\x1b[3;4H\x1bP0;1q\"1;1;2;6#1;2;100;0;0!2~\x1b\\")
            packets = owner.output(b"\x1b[3;1H\x1b[2K")
            state = next(h["scene"]["graphics"] for h, _ in packets if h.get("scene", {}).get("graphics") is not None)
            self.assertEqual(state["placements"], [])
            self.assertTrue(all(not h["scene"]["snapshot"] for h, _ in packets if h.get("type") == "terminal"))


if __name__ == "__main__":
    unittest.main()
