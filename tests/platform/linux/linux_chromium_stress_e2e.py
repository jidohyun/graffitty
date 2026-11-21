#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Owned Linux Chromium multi-client, GPU recovery and bounded soak test.

The optional private Unix bridge lets a separate network namespace impose real
netem loss/delay on its TCP leg without changing the host or sandbox network.
"""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import signal
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time

sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/chromium", "tests/support")]
from headless_remote_e2e import Client
from chromium_video_e2e import evaluate
from chromium_slow_link_e2e import PAGE


class Stream:
    def __init__(self, descriptor, sid, codecs=None, quality=None, ack_delay=0, rate_kb=0, paused=False, allow_unavailable=False, workspace="main"):
        self.client = Client(descriptor, workspace=workspace, chromium_video=codecs or ["hevc", "h264"],
                             chromium_stream=quality, receive_buffer=32768,
                             chromium_image_format=None if allow_unavailable else "png")
        self.client.action("subscribe", sessions=[sid])
        self.sid = sid
        self.delay, self.rate = ack_delay, rate_kb * 1024
        self.stop = threading.Event()
        self.paused = threading.Event()
        if paused:
            self.paused.set()
        self.lock = threading.Lock()
        self.frames = deque(maxlen=7200)
        self.responses = deque(maxlen=128)
        self.sample = []
        self.sample_epoch = None
        self.latest = None
        self.error = None
        self.unavailable = None
        self.allow_unavailable = allow_unavailable
        self.received_headers = deque(maxlen=4096)
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()

    def receive(self):
        acks = deque()
        budget, before = 0., time.monotonic()
        try:
            self.client.ws.settimeout(.1)
            while not self.stop.is_set():
                if self.paused.is_set():
                    self.stop.wait(.01)
                    continue
                now = time.monotonic()
                while acks and acks[0][0] <= now:
                    self.client.ws.send(acks.popleft()[1])
                if self.rate:
                    budget = min(budget + (now - before) * self.rate, self.rate)
                before = now
                if self.rate and budget <= 0:
                    time.sleep(.005)
                    continue
                try:
                    value = self.client.ws.recv()
                except Exception as error:
                    if "timed out" in str(error):
                        continue
                    raise
                if not isinstance(value, bytes):
                    with self.lock:
                        self.responses.append((time.monotonic(), json.loads(value)))
                    continue
                assert value[:4] == b"GRT2"
                size = struct.unpack("<I", value[4:8])[0]
                header = json.loads(value[8:8 + size])
                if header.get("type") == "chromium":
                    with self.lock:
                        self.received_headers.append((time.monotonic(), header))
                if header.get("type") != "chromium" or header.get("session") != self.sid:
                    continue
                if header.get("format") == "error" and self.allow_unavailable:
                    self.unavailable = header
                    continue
                assert header.get("format") in ("hevc", "h264"), header
                payload = value[8 + size:]
                now = time.monotonic()
                if self.rate:
                    budget -= len(value)
                acks.append((now + self.delay, json.dumps({"type": "chromium_ack", "session": self.sid, "frame": header["frame"]})))
                with self.lock:
                    self.latest = header
                    self.frames.append((now, header["epoch"], header["sequence"], header["key"], len(value)))
                    if header["key"] and (not self.sample or self.sample_epoch != header["epoch"]):
                        self.sample = [payload]
                        self.sample_epoch = header["epoch"]
                    elif self.sample_epoch == header["epoch"] and self.sample and len(self.sample) < 60:
                        self.sample.append(payload)
        except Exception as error:
            if not self.stop.is_set():
                self.error = repr(error)

    def action(self, kind, **args):
        self.client.action(kind, self.sid, **args)

    def response(self, request):
        with self.lock:
            reply = next(((at, value) for at, value in self.responses if value.get("request") == request), None)
        if reply is None:
            return None
        assert reply[1]["type"] == "ack", reply[1]
        return reply[0]

    def reset_sample(self):
        with self.lock:
            self.sample = []
            self.sample_epoch = None
        self.action("chromium_video_reset")

    def stats(self, since):
        assert self.error is None, self.error
        with self.lock:
            frames = [f for f in self.frames if f[0] >= since]
            latest = dict(self.latest or {})
        gaps = [b[0] - a[0] for a, b in zip(frames, frames[1:])]
        return {"frames": len(frames), "fps": len(frames) / max(.001, time.monotonic() - since),
                "longest_gap_s": max(gaps, default=0), "keyframes": sum(f[3] for f in frames), "latest": latest}

    def decode(self, directory, name):
        with self.lock:
            chunks, header = list(self.sample), dict(self.latest or {})
        assert len(chunks) >= 30, f"Only {len(chunks)} encoded samples"
        path = directory / (name + "." + header["format"])
        path.write_bytes(b"".join(chunks))
        result = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-f", header["format"], "-i", str(path),
                                 "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], capture_output=True, timeout=30)
        (directory / (name + "-decode.log")).write_bytes(result.stderr)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        colors = {result.stdout[i:i+3] for i in range(0, len(result.stdout), 3)}
        assert len(result.stdout) // 3 >= 30 and len(colors) > 5, "Decoded video is missing or frozen"
        return {"decoded_frames": len(result.stdout) // 3, "distinct_colors": len(colors)}

    def close(self):
        self.stop.set()
        self.client.ws.close()
        self.thread.join(timeout=3)


def eventually(predicate, message, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError(message)


def parent(pid):
    return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])


def descendants(root):
    parents = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            try:
                parents[int(entry.name)] = parent(int(entry.name))
            except (OSError, ValueError):
                pass
    owned = {root}
    while True:
        children = {pid for pid, ppid in parents.items() if ppid in owned}
        if children <= owned:
            return owned
        owned |= children


def gpu_processes(host):
    result = []
    for pid in descendants(host) - {host}:
        try:
            args = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").split()
            if b"--type=gpu-process" in args:
                result.append(pid)
        except OSError:
            pass
    return result


def memory(server, host, *, proc_root=Path('/proc'), cgroup_root=Path('/sys/fs/cgroup')):
    status = (proc_root / str(server) / 'status').read_text()
    rss = int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:'))) * 1024
    group = next(line[3:] for line in (proc_root / str(host) / 'cgroup').read_text().splitlines() if line.startswith('0::'))
    group = cgroup_root / group.lstrip('/')
    assert group.name.startswith(f'godot-terminal-{server}-'), 'Browser must have a fixture-owned cgroup'
    counters = lambda path: {key: int(value) for key, value in (line.split() for line in path.read_text().splitlines())}
    processes = []
    for membership in [group / 'cgroup.procs', *group.glob('**/*/cgroup.procs')]:
        for pid in membership.read_text().split():
            path = proc_root / pid
            try:
                identity = (path / 'stat').read_text().rsplit(')', 1)[1].split()[19]
                argv = (path / 'cmdline').read_bytes().split(b'\0')
                kind = next((arg.removeprefix(b'--type=').decode() for arg in argv if arg.startswith(b'--type=')), 'browser' if int(pid) == host else 'subprocess')
                row = {'pid': int(pid), 'start': identity, 'kind': kind}
                try:
                    # Diagnostic breakdown only. RSS double-counts shared pages;
                    # never replace the cgroup acceptance limit with summed RSS.
                    row['smaps_bytes'] = {parts[0].rstrip(':'): int(parts[1]) * 1024
                        for line in (path / 'smaps_rollup').read_text().splitlines()
                        if len(parts := line.split()) == 3 and parts[2] == 'kB'}
                except (OSError, ValueError) as error:
                    row['smaps_error'] = type(error).__name__
                if (path / 'stat').read_text().rsplit(')', 1)[1].split()[19] == identity:
                    processes.append(row)
            except (OSError, IndexError):
                continue # A child can exit between membership and /proc reads.
    return {'server_rss': rss, 'browser_cgroup': int((group / 'memory.current').read_text()),
            'server_fds': len(list((proc_root / str(server) / 'fd').iterdir())),
            'browser_memory_stat': counters(group / 'memory.stat'),
            'browser_memory_events': counters(group / 'memory.events'),
            'browser_process_memory': processes}


class Bridge:
    def __init__(self, path, port):
        self.path = path
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(path))
        os.chmod(path, 0o600)
        self.listener.listen()
        self.port = port
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while True:
            try:
                client, _ = self.listener.accept()
                upstream = socket.create_connection(("127.0.0.1", self.port))
            except OSError:
                return
            threading.Thread(target=self.copy, args=(client, upstream), daemon=True).start()
            threading.Thread(target=self.copy, args=(upstream, client), daemon=True).start()

    @staticmethod
    def copy(source, target):
        try:
            while data := source.recv(65536):
                target.sendall(data)
        except OSError:
            pass
        finally:
            try:
                target.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def close(self):
        self.listener.close()
        self.path.unlink(missing_ok=True)


def run(args):
    from urllib.parse import urlsplit
    os.umask(0o077)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, GRAFFITTY_CHROMIUM_HOST=str(args.host.resolve()),
               GRAFFITTY_SERVER__CHROMIUM__BACKEND=args.backend, GRAFFITTY_CHROMIUM_OZONE_PLATFORM=args.platform,
               SHELL="/bin/sh")
    for name in ("CONFIG", "STATE", "DATA"):
        env[f"XDG_{name}_HOME"] = str(out / name.lower())
    if args.platform == "wayland":
        env.pop("DISPLAY", None)
    viewers, bridge, owner = [], None, None
    results = {}
    with (out / "server.log").open("wb") as log:
        server = subprocess.Popen([str(args.server.resolve()), "server", "--listen", "127.0.0.1:0", "--connection", str(out / "connection.json"),
                                   "--auth-file", str(out / "auth.json"), "--shell", "/bin/sh"], env=env, stdout=log, stderr=log)
        try:
            eventually(lambda: (out / "connection.json").exists(), "Server did not start")
            descriptor = json.loads((out / "connection.json").read_text())
            owner = Client(descriptor)
            pane, request = owner.topology["panes"][0]["id"], 0

            def rpc(method, **params):
                nonlocal request
                request += 1
                owner.action("rpc", pane, request=request, method=method, params=params)
                owner.until(lambda: any(m.get("request") == request for m in owner.messages))
                message = next(m for m in owner.messages if m.get("request") == request)
                assert message["type"] == "ack", message
                owner.messages.clear()
                return message["result"]

            created = rpc("chromium.create", url="about:blank")["chromium"]
            sid = int(created[1:])
            owner.until(lambda: any(b["id"] == sid and b["state"].get("chromiumId", -1) > 0 for b in owner.topology.get("chromiums", [])))
            host = next(b["state"]["pid"] for b in owner.topology["chromiums"] if b["id"] == sid)
            assert host in descendants(server.pid)
            rpc("chromium.command", chromium=created, action="resize", args={"width": 1000, "height": 700})
            evaluate(rpc, created, "document.open();document.write(" + json.dumps(PAGE) + ");document.close();window.stressIdentity='retained';true")
            bridge = Bridge(args.bridge, urlsplit(descriptor["url"]).port)
            (out / "ready.json").write_text(json.dumps({"descriptor": descriptor, "chromium": sid, "server": server.pid, "host": host}))
            fast = Stream(descriptor, sid)
            viewers.append(fast)
            eventually(lambda: fast.latest, "First hardware stream missing")
            start = time.monotonic()
            time.sleep(10)
            baseline = fast.stats(start)
            assert baseline["fps"] >= 20, baseline
            low = Stream(descriptor, sid, codecs=["h264"], quality={"max_height": 360, "fps": 15, "bitrate_kbps": 2000})
            viewers.append(low)
            slow = Stream(descriptor, sid, ack_delay=.13, rate_kb=500)
            viewers.append(slow)
            start = time.monotonic()
            for _ in range(20):
                evaluate(rpc, created, "performance.now()")
                time.sleep(1)
            shared = {"fast": fast.stats(start), "low": low.stats(start), "slow": slow.stats(start)}
            assert shared["fast"]["fps"] >= baseline["fps"] * .75, shared
            assert shared["low"]["latest"]["height"] <= 360 and shared["low"]["latest"]["format"] == "h264", shared
            assert shared["slow"]["fps"] >= 5, shared
            results["multi_client"] = {"baseline": baseline, **shared, "decode": fast.decode(out, "multi-client")}
            slow.close()
            viewers.remove(slow)
            old_gpu = gpu_processes(host)
            assert old_gpu, "No owned Chromium GPU process"
            for pid in old_gpu:
                os.kill(pid, signal.SIGKILL)
            killed_at = time.monotonic()
            eventually(lambda: set(gpu_processes(host)) - set(old_gpu), "GPU process was not replaced")
            eventually(lambda: fast.stats(killed_at)["frames"] >= 60, "Hardware video did not recover after GPU process termination")
            assert evaluate(rpc, created, "window.stressIdentity") == "retained", "GPU recovery replaced the document"
            fast.reset_sample()
            eventually(lambda: len(fast.sample) >= 60, "Recovered video sample missing")
            results["gpu_recovery"] = {"seconds": time.monotonic() - killed_at, "host_pid": host,
                                       "killed_gpu_pids": old_gpu, "replacement_gpu_pids": gpu_processes(host),
                                       "decode": fast.decode(out, "gpu-recovered")}
            old_epoch = fast.latest["epoch"]
            rpc("chromium.command", chromium=created, action="resize", args={"width": 800, "height": 600})
            eventually(lambda: fast.latest["epoch"] != old_epoch and fast.latest["width"] == 800, "Encoder was not recreated on resize")
            fast.reset_sample()
            eventually(lambda: len(fast.sample) >= 60, "Recreated encoder sample missing")
            results["encoder_recreation"] = fast.decode(out, "encoder-recreated")
            (out / "phase-results.json").write_text(json.dumps(results, indent=2))
            print("PASS multi-client, GPU process recovery, encoder recreation", flush=True)
            if args.skip_soak:
                results["soak"] = {"status": "not_run"}
                (out / "results.json").write_text(json.dumps(results, indent=2))
                return
            samples = []
            started = time.monotonic()
            next_churn = 0
            while time.monotonic() - started < args.seconds:
                elapsed = time.monotonic() - started
                assert evaluate(rpc, created, "window.stressIdentity") == "retained"
                point = {"elapsed": elapsed, **memory(server.pid, host), "fast": fast.stats(time.monotonic() - 5), "low": low.stats(time.monotonic() - 5)}
                assert point["fast"]["fps"] >= 20 and point["low"]["frames"] > 0, point
                samples.append(point)
                (out / "soak.json").write_text(json.dumps(samples, indent=2))
                if elapsed >= next_churn:
                    late = Stream(descriptor, sid, ack_delay=.25)
                    try:
                        eventually(lambda: late.latest, "Late subscriber did not start")
                        assert late.sample, "Late subscriber did not get a keyframe"
                        time.sleep(2)  # Exercise private pacing allocation and retirement.
                    finally:
                        late.close()
                    next_churn += 20
                time.sleep(5)
            assert len(samples) >= 48, "Soak must have disjoint warm-up and final measurement windows"
            early = [s for s in samples if 60 <= s["elapsed"] <= 120]
            late = samples[-12:]
            growth = {}
            for key, allowance in [("server_rss", 128 * 1024**2), ("browser_cgroup", 256 * 1024**2), ("server_fds", 32)]:
                first, last = statistics.median(s[key] for s in early), statistics.median(s[key] for s in late)
                growth[key] = {"early": first, "late": last, "growth": last - first,
                               "peak": max(s[key] for s in samples), "allowance": allowance}
                assert last - first <= allowance, growth
            results["soak"] = {"seconds": time.monotonic() - started, "samples": len(samples), "growth": growth}
            (out / "results.json").write_text(json.dumps(results, indent=2))
            print("PASS soak", json.dumps(results["soak"]), flush=True)
        finally:
            failed = sys.exc_info()[0] is not None
            for client in viewers:
                client.close()
            if owner:
                owner.ws.close()
            if bridge:
                bridge.close()
            server.terminate()
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=10)
            parent_group = Path(env.get("GODOT_RESOURCE_CGROUP_PARENT", "/sys/fs/cgroup"))
            cleanup = {"exit": server.returncode, "leaked_cgroups": [p.name for p in parent_group.glob(f"godot-terminal-{server.pid}-*")]}
            (out / "cleanup.json").write_text(json.dumps(cleanup))
            if not failed:
                assert cleanup == {"exit": 0, "leaked_cgroups": []}, cleanup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--backend", choices=["chrome", "alloy"], required=True)
    parser.add_argument("--platform", choices=["wayland", "x11"], default="wayland")
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--skip-soak", action="store_true", help="Run fanout/GPU/encoder checks only; record soak as not run")
    args = parser.parse_args()
    if not args.skip_soak and args.seconds < 240:
        parser.error("--seconds must be at least 240")
    run(args)


if __name__ == "__main__":
    main()
