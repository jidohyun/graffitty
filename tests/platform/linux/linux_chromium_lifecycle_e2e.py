#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2", "nvidia-ml-py>=13,<14"]
# ///
"""Owned Linux browser capacity, fresh-connection, and lifecycle regressions."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/chromium", "tests/support")]
from headless_remote_e2e import Client
from chromium_video_e2e import evaluate
from linux_chromium_stress_e2e import Stream, eventually, memory


class Fixture:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        env = dict(os.environ, GRAFFITTY_CHROMIUM_HOST=str(args.host.resolve()),
                   GRAFFITTY_CHROMIUM_OZONE_PLATFORM=args.platform,
                   GRAFFITTY_SERVER__CHROMIUM__BACKEND=args.backend, SHELL="/bin/sh")
        if args.platform == "wayland":
            env.pop("DISPLAY", None)
        for key in ("CONFIG", "STATE", "DATA"):
            env[f"XDG_{key}_HOME"] = str(self.out / key.lower())
        self.log = (self.out / "server.log").open("wb")
        self.server = subprocess.Popen([str(args.server.resolve()), "server", "--listen", "127.0.0.1:0",
            "--connection", str(self.out / "connection.json"), "--auth-file", str(self.out / "auth.json"),
            "--shell", "/bin/sh"], env=env, stdout=self.log, stderr=self.log)
        self.clients = []
        self.owner = None
        self.request = 0
        self.env = env

    def __enter__(self):
        try:
            eventually(lambda: (self.out / "connection.json").exists(), "Fixture server did not start")
            self.descriptor = json.loads((self.out / "connection.json").read_text())
            self.owner = Client(self.descriptor)
            self.pane = self.owner.topology["panes"][0]["id"]
            return self
        except BaseException:
            self.__exit__(True, None, None)
            raise

    def rpc(self, method, **params):
        self.request += 1
        self.owner.action("rpc", self.pane, request=self.request, method=method, params=params)
        self.owner.until(lambda: any(v.get("request") == self.request for v in self.owner.messages))
        reply = next(v for v in self.owner.messages if v.get("request") == self.request)
        assert reply["type"] == "ack", reply
        self.owner.messages.clear()
        return reply["result"]

    def page(self, identity, channel=0):
        created = self.rpc("chromium.create", url="about:blank")["chromium"]
        sid = int(created[1:])
        self.owner.until(lambda: any(b["id"] == sid and b["state"].get("chromiumId", -1) > 0
                                    for b in self.owner.topology.get("chromiums", [])))
        host = next(b["state"]["pid"] for b in self.owner.topology["chromiums"] if b["id"] == sid)
        self.rpc("chromium.command", chromium=created, action="resize", args={"width": 800, "height": 600})
        page = "document.body.style.margin='0';window.testIdentity=" + json.dumps(identity) + ";" \
            + "let n=0;function tick(){let c=[0,0,0];c[" + str(channel) + "]=170+(n++%70);" \
            + "document.body.style.background='rgb('+c.join(',')+')';requestAnimationFrame(tick)}tick();true"
        assert evaluate(self.rpc, created, page)
        return created, sid, host

    def stream(self, sid, **kwargs):
        stream = Stream(self.descriptor, sid, **kwargs)
        self.clients.append(stream)
        return stream

    def save(self, name, value):
        (self.out / name).write_text(json.dumps(value, indent=2))

    def __exit__(self, error, *_):
        for client in self.clients:
            client.close()
        if self.owner:
            self.owner.ws.close()
        self.server.terminate()
        try:
            self.server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait(timeout=10)
        self.log.close()
        parent = Path(self.env.get("GODOT_RESOURCE_CGROUP_PARENT", "/sys/fs/cgroup"))
        cleanup = {"exit": self.server.returncode, "leaked_cgroups": [p.name for p in parent.glob(f"godot-terminal-{self.server.pid}-*")]}
        self.save("cleanup.json", cleanup)
        if not error:
            assert cleanup == {"exit": 0, "leaked_cgroups": []}, cleanup


class Encoders:
    def __init__(self):
        import pynvml as nv
        nv.nvmlInit()
        self.nv = nv
        self.device = nv.nvmlDeviceGetHandleByIndex(0)
        self.before = {s.sessionId for s in nv.nvmlDeviceGetEncoderSessions(self.device)}
        self.pid = None

    def sessions(self):
        all_sessions = self.nv.nvmlDeviceGetEncoderSessions(self.device)
        if self.pid is None:
            fresh = {s.pid for s in all_sessions if s.sessionId not in self.before}
            if fresh:
                assert len(fresh) == 1, "Competing encoder workloads: run capacity testing alone"
                self.pid = fresh.pop()
        return [dict(pid=s.pid, id=s.sessionId, codec=s.codecType, width=s.hResolution, height=s.vResolution)
                for s in all_sessions if s.pid == self.pid]


def capacity(f, startup=False):
    with ExitStack() as nested:
        capacity_body(f, nested, startup)


def capacity_body(f, nested, startup):
    gpu = Encoders()
    page, sid, _ = f.page("capacity")
    fast = f.stream(sid, allow_unavailable=True)
    eventually(lambda: fast.latest, "Healthy stream did not start")
    eventually(lambda: len(gpu.sessions()) == 1, "Expected one shared hardware encoder")
    start = time.monotonic()
    time.sleep(5)
    baseline = fast.stats(start)
    peers, records = [], []
    failed = None
    for index in range(16):
        peer = f.stream(sid, ack_delay=.65, allow_unavailable=True)
        peers.append(peer)
        eventually(lambda: peer.latest or peer.unavailable, "New peer received neither video nor an error")
        time.sleep(2)
        record = {"peer": index, "sessions": gpu.sessions(), "unavailable": peer.unavailable}
        records.append(record)
        f.save("capacity-attempts.json", records)
        if peer.unavailable:
            failed = peer
            break
    assert failed is not None, "Did not exercise actual hardware capacity exhaustion (16 independent slow peers)"
    assert "No shared hardware video codec" in failed.unavailable.get("error", ""), failed.unavailable
    assert len(gpu.sessions()) >= 2, "No independently paced encoder was allocated"
    start = time.monotonic()
    time.sleep(5)
    stressed = fast.stats(start)
    assert stressed["fps"] >= baseline["fps"] * .75 and stressed["longest_gap_s"] < 1, stressed
    before_resize = fast.latest["epoch"]
    f.rpc("chromium.command", chromium=page, action="resize", args={"width": 960, "height": 540})
    eventually(lambda: fast.latest["epoch"] != before_resize and fast.latest["width"] == 960,
               "A full encoder pool prevented resizing an existing rendition")
    fast.reset_sample()
    eventually(lambda: len(fast.sample) >= 60, "Resized stream did not produce a fresh sample")
    resized_decode = fast.decode(f.out, "capacity-resized")
    # A different shared quality fails while the hardware pool is full. It must
    # be usable on this browser again when the other viewers release capacity.
    quality = {"max_height": 360, "fps": 15, "bitrate_kbps": 1500}
    unavailable = f.stream(sid, quality=quality, allow_unavailable=True)
    eventually(lambda: unavailable.unavailable, "Expected explicit capacity error for a new rendition")
    newborn, newborn_stream = None, None
    if startup:
        settings = argparse.Namespace(**vars(f.args))
        settings.output = f.out / "startup-server"
        newborn = nested.enter_context(Fixture(settings))
        newborn_page, newborn_sid, _ = newborn.page("started-under-pressure")
        newborn_stream = newborn.stream(newborn_sid, allow_unavailable=True)
        eventually(lambda: newborn_stream.unavailable, "New server did not observe hardware exhaustion")
        assert newborn_stream.latest is None
    for peer in peers:
        peer.close()
    eventually(lambda: len(gpu.sessions()) <= 2, "Disconnected peers retained their encoders")
    eventually(lambda: unavailable.latest, "Existing failed viewer did not recover after capacity was released", timeout=15)
    eventually(lambda: len(unavailable.sample) >= 60, "Recovered viewer did not receive moving video")
    waiting_decode = unavailable.decode(f.out, "waiting-capacity-recovered")
    unavailable.close()
    time.sleep(.5)
    retry = f.stream(sid, quality=quality, allow_unavailable=True)
    eventually(lambda: retry.latest, "Freed encoder capacity did not become usable again on the same browser", timeout=15)
    eventually(lambda: len(retry.sample) >= 60, "Recovered capacity did not deliver moving frames")
    result = {"status": "pass", "peak_sessions": max(len(x["sessions"]) for x in records),
              "baseline": baseline, "under_exhaustion": stressed, "attempts": records,
              "resize_at_capacity": resized_decode, "waiting_decode": waiting_decode, "recovered_decode": retry.decode(f.out, "capacity-recovered")}
    if newborn is not None:
        eventually(lambda: newborn_stream.latest, "Server started under pressure permanently cached an empty codec list", timeout=15)
        eventually(lambda: len(newborn_stream.sample) >= 60, "New server failed to deliver a decode sample")
        result["startup_decode"] = newborn_stream.decode(f.out, "startup-capacity-recovered")
        assert evaluate(newborn.rpc, newborn_page, "window.testIdentity") == "started-under-pressure"
    assert evaluate(f.rpc, page, "window.testIdentity") == "capacity"
    retry.close()
    eventually(lambda: len(gpu.sessions()) == 1, "Recovery rendition retained an encoder")
    fast.close()
    eventually(lambda: not gpu.sessions(), "All subscribers gone but encoders remain")
    f.save("results.json", result)
    print("PASS capacity exhaustion, healthy-peer isolation, capacity reuse, and encoder retirement", flush=True)


def abort(stream):
    """Close TCP with RST, without sending a WebSocket close handshake."""
    stream.stop.set()
    connection = stream.client.ws.sock
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    connection.close()
    stream.thread.join(timeout=3)


def decode_color(stream, out, name, channel):
    decoded = stream.decode(out, name)
    path = out / (name + "." + stream.latest["format"])
    result = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(path),
        "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], capture_output=True, check=True, timeout=30)
    pixels = [result.stdout[i:i+3] for i in range(0, len(result.stdout), 3)]
    assert all(pixel[channel] > 120 and all(v < 35 for i, v in enumerate(pixel) if i != channel)
               for pixel in pixels), "Video contains another tab's pixels"
    return decoded


def reconnect(f):
    gpu = Encoders()
    page, sid, host = f.page("reconnect")
    healthy = f.stream(sid)
    eventually(lambda: healthy.latest, "Healthy viewer did not start")
    eventually(lambda: len(gpu.sessions()) == 1, "Expected one encoder")
    records = []
    for cycle in range(10):
        slow = f.stream(sid, ack_delay=.65)
        eventually(lambda: len(gpu.sessions()) == 2, "Slow connection did not receive independent pacing")
        previous_socket = slow.client.ws.sock.getsockname()
        abort(slow)
        eventually(lambda: len(gpu.sessions()) == 1, "Reset connection retained its private encoder")
        fresh = f.stream(sid)
        assert fresh.client.ws.sock.getsockname() != previous_socket, "Reconnect reused the old socket"
        started = time.monotonic()
        eventually(lambda: len(fresh.sample) >= 60, "Fresh authenticated connection did not receive decodable video")
        frames = [h for _, h in fresh.received_headers if h.get("session") == sid and h.get("format") in ("hevc", "h264")]
        assert frames and frames[0]["key"], "Fresh connection started with a dependent frame"
        record = {"cycle": cycle, "seconds": time.monotonic() - started,
                  "decode": decode_color(fresh, f.out, f"reconnect-{cycle}", 0)}
        assert evaluate(f.rpc, page, "window.testIdentity") == "reconnect"
        f.owner.until(lambda: any(b["id"] == sid for b in f.owner.topology.get("chromiums", [])))
        assert next(b["state"]["pid"] for b in f.owner.topology["chromiums"] if b["id"] == sid) == host
        records.append(record)
        f.save("reconnect-cycles.json", records)
        fresh.close()
        assert healthy.stats(started)["frames"] >= 20
    healthy.close()
    eventually(lambda: not gpu.sessions(), "Reconnect test retained encoder sessions")
    f.save("results.json", {"status": "pass", "cycles": records})
    print("PASS ten TCP resets, fresh authentication/subscription, document retention, and decoding", flush=True)


def churn(f):
    gpu = Encoders()
    anchor, anchor_id, host = f.page("anchor", 0)
    healthy = f.stream(anchor_id)
    eventually(lambda: healthy.latest, "Anchor viewer missing")
    eventually(lambda: len(gpu.sessions()) == 1, "Expected one anchor encoder")
    initial = memory(f.server.pid, host)
    cycles = []
    for cycle in range(20):
        page, sid, _ = f.page(f"tab-{cycle}", 1)
        viewer = f.stream(sid)
        slow = f.stream(anchor_id, ack_delay=.65)
        eventually(lambda: viewer.latest, "New tab did not receive video")
        # Queue several size/subscription changes before waiting for final state.
        for width, height in ((640, 480), (960, 540), (720, 480)):
            f.rpc("chromium.command", chromium=page, action="resize", args={"width": width, "height": height})
            viewer.client.action("subscribe", sessions=[])
            viewer.client.action("subscribe", sessions=[sid])
        eventually(lambda: viewer.latest["width"] == 720 and viewer.latest["height"] == 480, "Final resize did not settle")
        viewer.reset_sample()
        eventually(lambda: len(viewer.sample) >= 60, "Final tab sample missing")
        checked = decode_color(viewer, f.out, f"tab-{cycle}", 1)
        viewer.client.action("subscribe", sessions=[])
        request = 100000 + cycle
        viewer.client.action("rpc", f.pane, request=request, method="session.capture", params={})
        boundary = eventually(lambda: viewer.response(request), "Unsubscribe barrier failed")
        f.rpc("chromium.close", chromium=page)
        slow.close()
        time.sleep(.2)
        assert not [h for at, h in viewer.received_headers if at > boundary and h.get("session") == sid], "Frames arrived for an unsubscribed tab"
        viewer.close()
        eventually(lambda: len(gpu.sessions()) == 1, "Closed tab/slow peer retained encoders")
        assert evaluate(f.rpc, anchor, "window.testIdentity") == "anchor"
        point = {"cycle": cycle, **memory(f.server.pid, host), "decode": checked}
        cycles.append(point)
        f.save("churn-cycles.json", cycles)
    healthy.reset_sample()
    eventually(lambda: len(healthy.sample) >= 60, "Anchor stopped after tab churn")
    anchor_decode = decode_color(healthy, f.out, "anchor-after-churn", 0)
    final = memory(f.server.pid, host)
    assert final["server_fds"] <= initial["server_fds"] + 4, (initial, final)
    assert final["server_rss"] <= initial["server_rss"] + 128 * 1024**2, (initial, final)
    healthy.close()
    eventually(lambda: not gpu.sessions(), "Churn retained encoder sessions")
    f.save("results.json", {"status": "pass", "cycles": cycles, "initial": initial, "final": final, "anchor_decode": anchor_decode})
    print("PASS twenty tab/resize/subscription/slow-peer cycles, pixel ownership, and retirement", flush=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=["chrome", "alloy"], required=True)
    parser.add_argument("--platform", choices=["wayland", "x11"], default="wayland")
    parser.add_argument("--case", choices=["capacity", "startup-capacity", "reconnect", "churn"], required=True)
    args = parser.parse_args()
    with Fixture(args) as fixture:
        {"capacity": capacity, "startup-capacity": lambda f: capacity(f, startup=True), "reconnect": reconnect, "churn": churn}[args.case](fixture)


if __name__ == "__main__":
    main()
