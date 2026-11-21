# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Test Chromium video over UDP with a real owner and Godot client.

The test owns an isolated server and profile. Godot logs in over loopback
with the owner's password. The encrypted session offers video datagrams
alongside the WebSocket.

- Confirm video moves to UDP. Pause the pane and check that frames stop
  arriving. Resume and check that playback starts at a keyframe.
- Stop the client's datagram link and check that video returns to the
  WebSocket.
- Drop 5% of datagrams on a second client. Parity and retransmission
  must keep its video decoding.
- Share a 10 Mbps and then a 4 Mbps tunnel among three browsers drawing
  full-page noise. Every stream must keep moving without freezes or
  keyframe storms by lowering its live encoder bitrate.

`GRAFFITTY_TEST_DATAGRAM_RATE` sets the tunnel's shallow drop-tail queue.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client

ROOT = Path(__file__).resolve().parents[2]
ANIMATION = ("document.body.style.margin='0';document.body.style.font='32px sans-serif';"
             "let n=0;function f(){n++;document.body.textContent='frame '+n;"
             "document.body.style.background='hsl('+(n*7%360)+',70%,60%)';requestAnimationFrame(f)}f();1")
# Full-page noise defeats inter-frame prediction, like video or fast scrolling.
NOISE = ("document.body.style.margin='0';const c=document.createElement('canvas');c.width=innerWidth;"
         "c.height=innerHeight;c.style.display='block';document.body.appendChild(c);const g=c.getContext('2d');"
         "const img=g.createImageData(c.width,c.height);const px=new Uint32Array(img.data.buffer);"
         "function f(){for(let i=0;i<px.length;i++)px[i]=0xff000000|(Math.random()*0xffffff);"
         "g.putImageData(img,0,0);requestAnimationFrame(f)}f();1")
# Narrow tunnels for three streams that would each take more: 10 Mbps, and
# 4 Mbps where only lower bitrates keep every stream moving.
BOTTLENECKS_BYTES_PER_SECOND = ["1250000", "500000"]


def main():
    with tempfile.TemporaryDirectory(prefix="gr-datagram-") as scratch:
        descriptor_path = Path(scratch) / "server.json"
        log_path = Path(scratch) / "server.log"
        log = open(log_path, "w")
        server = subprocess.Popen([BINARY, "server", "--listen", "127.0.0.1:0",
            "--connection", descriptor_path, "--auth-file", Path(scratch) / "auth.json",
            "--shell", "/bin/sh"], stdout=log, stderr=log)
        owner = None
        try:
            for _ in range(200):
                if descriptor_path.exists():
                    break
                assert server.poll() is None
                time.sleep(.025)
            descriptor = json.loads(descriptor_path.read_text())
            owner = Client(descriptor, chromium_video=["h264", "hevc", "av1"])
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

            def browser(expression):
                target = rpc("chromium.create", url="about:blank")["chromium"]
                chromium = int(target[1:])
                owner.until(lambda: any(b["id"] == chromium and b["state"].get("chromiumId", -1) > 0
                                        for b in owner.topology.get("chromiums", [])))
                ticket = rpc("chromium.command", chromium=target, action="cdp", args={
                    "method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": True}})["ticket"]
                deadline = time.monotonic() + 10
                while (result := rpc("chromium.result", chromium=target, ticket=ticket)) is None:
                    assert time.monotonic() < deadline, "Page animation did not start"
                    time.sleep(.025)
                assert "error" not in result, result
                return chromium

            chromium = browser(ANIMATION)
            def godot(*extra, env=None):
                try:
                    gd = subprocess.run([
                        os.environ.get("GODOT") or shutil.which("godot"), "--headless",
                        "--path", str(ROOT / "frontends/godot/project"), "--script",
                        "tests/chromium_video_datagram_e2e.gd", "--",
                        str(descriptor_path), str(pane), str(chromium), *extra,
                    ], capture_output=True, text=True, timeout=90, env={**os.environ, **(env or {}), **{
                        "XDG_" + kind + "_HOME": str(Path(scratch) / kind.lower())
                        for kind in ["CONFIG", "STATE", "DATA", "CACHE"]
                    }})
                except subprocess.TimeoutExpired as error:
                    print(error.stdout, error.stderr, flush=True)
                    raise
                print(gd.stdout, end="")
                assert gd.returncode == 0 and "CHROMIUM_VIDEO_DATAGRAM_PASS" in gd.stdout, (
                    gd.stdout + gd.stderr + "\nserver log tail:\n" + log_path.read_text()[-3000:])
                assert "SCRIPT ERROR" not in gd.stderr, gd.stderr

            godot()
            server_log = log_path.read_text()
            assert "video moved to udp" in server_log, server_log[-4000:]
            assert "video returns to the WebSocket: hellos stopped" in server_log, server_log[-4000:]
            print("PASS owner logged the move to datagrams and the return to the WebSocket")
            godot("lossy", env={"GRAFFITTY_TEST_DATAGRAM_LOSS": "5"})
            print("PASS 5% datagram loss repaired by parity and retransmission")
            noisy = [browser(NOISE) for _ in range(3)]
            for rate in BOTTLENECKS_BYTES_PER_SECOND:
                before = len(log_path.read_text())
                godot("multi", *map(str, noisy), env={"GRAFFITTY_TEST_DATAGRAM_RATE": rate})
                during = log_path.read_text()[before:]
                # The client disconnects normally when its scenario ends.
                assert "video returns to the WebSocket" not in during, during[-4000:]
                print(f"PASS three noisy streams share a {int(rate) * 8 // 1_000_000} Mbps tunnel without leaving the datagram link")
            # A phone: 25 rendered frames a second behind 50 ms of latency.
            #
            # Noise frames of 200-360 KB exceed the tunnel's queue; a keyframe
            # must flush the stale frames ahead of it instead of waiting
            # behind them.
            godot("paced", *map(str, noisy), env={"GRAFFITTY_TEST_DATAGRAM_RATE": BOTTLENECKS_BYTES_PER_SECOND[0],
                                                  "GRAFFITTY_TEST_DATAGRAM_DELAY": "50"})
            print("PASS a phone-paced client behind a delayed tunnel keeps every stream moving")
        finally:
            if owner is not None:
                owner.ws.close()
            server.terminate()
            server.wait(timeout=10)
            # Keep the whole owner log for diagnosis; the scratch directory goes.
            if os.environ.get("GRAFFITTY_E2E_SERVER_LOG"):
                shutil.copy(log_path, os.environ["GRAFFITTY_E2E_SERVER_LOG"])


if __name__ == "__main__":
    main()
