# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Test Chromium video on slow and distant links with an isolated server
and profile.

Limit socket reads to simulate low bandwidth. Delay acknowledgements
to simulate a long round trip.

- At low bandwidth, adapt the rendition while continuing to send P-frames.
- With spare bandwidth, keep the frame rate up despite the long round trip.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client

PAGE = """<!doctype html><style>html,body{margin:0;height:100%;overflow:hidden}body{font:28px sans-serif}
#t{white-space:pre}</style><div id=t></div><script>let n=0;function f(){n++;let s="";
for(let i=0;i<40;i++)s+=("Row "+i+" frame "+n+" "+Math.random().toString(36)+" ").repeat(3)+"\\n";
t.textContent=s;document.body.style.background="linear-gradient("+(n*7%360)+"deg,hsl("+(n*3%360)+",60%,70%),hsl("+(n*5%360)+",80%,40%))";
requestAnimationFrame(f)}f()</script>"""


def measure(descriptor, chromium, rate_kb, round_trip_ms, seconds=8.0, warmup=2.0):
    """Receive one chromium stream through an emulated link and return frame statistics."""
    client = Client(descriptor, chromium_video=["hevc", "h264"], receive_buffer=32 * 1024)
    client.ws.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024)
    client.action("subscribe", sessions=[chromium])
    frames, acks = [], []
    started = last = time.monotonic()
    budget = 0.0
    try:
        while time.monotonic() - started < warmup + seconds:
            now = time.monotonic()
            while acks and acks[0][0] <= now:
                client.ws.send(acks.pop(0)[1])
            budget = min(budget + (now - last) * rate_kb * 1024, 256 * 1024)
            last = now
            if budget <= 0:
                time.sleep(0.002)
                continue
            client.ws.settimeout(0.01)
            try:
                value = client.ws.recv()
            except Exception as error:
                if "timed out" not in str(error):
                    raise
                continue
            if not isinstance(value, bytes):
                continue
            budget -= len(value)
            header = json.loads(value[8:8 + struct.unpack("<I", value[4:8])[0]])
            if header.get("type") != "chromium" or "frame" not in header:
                continue
            acks.append((now + round_trip_ms / 1000, json.dumps(
                {"type": "chromium_ack", "session": header["session"], "frame": header["frame"]})))
            assert header.get("format") in ("hevc", "h264"), header
            if now - started >= warmup:
                frames.append((now, header["key"], len(value)))
    finally:
        client.ws.close()
    gaps = [b[0] - a[0] for a, b in zip(frames, frames[1:])]
    return {
        "rate_kb": rate_kb, "round_trip_ms": round_trip_ms, "fps": len(frames) / seconds,
        "frames": len(frames), "keyframes": sum(1 for f in frames if f[1]),
        "mean_kb": sum(f[2] for f in frames) / max(1, len(frames)) / 1024,
        "longest_gap_s": max(gaps, default=0.0),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gr-slow-link-") as scratch:
        path = Path(scratch) / "server.json"
        log = (args.output / "server.log").open("w")
        server = subprocess.Popen([BINARY, "server", "--listen", "127.0.0.1:0", "--connection", path,
            "--auth-file", Path(scratch) / "auth.json", "--shell", "/bin/sh"], stdout=log, stderr=log)
        try:
            for _ in range(200):
                if path.exists():
                    break
                assert server.poll() is None
                time.sleep(0.05)
            descriptor = json.loads(path.read_text())
            owner = Client(descriptor)
            pane = owner.topology["panes"][0]["id"]
            request = 0
            def rpc(method, **params):
                nonlocal request
                request += 1
                owner.action("rpc", pane, request=request, method=method, params=params)
                owner.until(lambda: any(m.get("request") == request for m in owner.messages))
                reply = next(m for m in owner.messages if m.get("request") == request)
                assert reply["type"] == "ack", reply
                return reply["result"]
            created = rpc("chromium.create", url="about:blank")
            chromium = int(created["chromium"][1:])
            owner.until(lambda: any(b["id"] == chromium and b["state"].get("chromiumId", -1) > 0
                                   for b in owner.topology.get("chromiums", [])))
            rpc("chromium.command", chromium=created["chromium"], action="resize", args={"width": 1000, "height": 1080})
            rpc("chromium.command", chromium=created["chromium"], action="cdp", args={"method": "Runtime.evaluate",
                "params": {"expression": "document.open();document.write(" + json.dumps(PAGE) + ");document.close();true"}})
            time.sleep(1)
            results = {}
            for name, rate, round_trip in [("local", 20000, 0), ("distant", 20000, 130), ("slow", 500, 0), ("slow_distant", 500, 130)]:
                results[name] = measure(descriptor, chromium, rate, round_trip)
                print(json.dumps({name: results[name]}), flush=True)
            (args.output / "results.json").write_text(json.dumps(results, indent=2))
            local = results["local"]["fps"]
            assert local >= 20, f"Unthrottled stream is too slow to compare: {results['local']}"
            # The acknowledgement window covers a long round trip when bandwidth allows.
            assert results["distant"]["fps"] >= 0.8 * local, results["distant"]
            for name in ("slow", "slow_distant"):
                result = results[name]
                # A rendition follows the link with P-frames; restarts would be keyframes.
                assert result["keyframes"] <= max(2, result["frames"] // 20), result
                assert result["fps"] >= 0.2 * local, result
            print("CHROMIUM_SLOW_LINK_PASS")
        finally:
            server.terminate()
            server.wait(timeout=15)
            log.close()


if __name__ == "__main__":
    main()
