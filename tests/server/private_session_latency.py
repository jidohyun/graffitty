# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Measure PTY echo versus private-core VT delivery, excluding GUI rendering.

Run: mise exec -- uv run tests/server/private_session_latency.py
Reports observations, not a timing assertion that would flake under machine load.
"""
import json
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import subprocess
import sys
import tempfile
import time

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from private_session_e2e import BINARY, PrivateClient


def summary(samples):
    ordered = sorted(samples)
    return dict(median_ms=round(statistics.median(samples), 3),
                p95_ms=round(ordered[int(len(ordered) * .95)], 3),
                max_ms=round(max(samples), 3), samples=len(samples))


def measure(send, receive):
    samples = []
    for i in range(220):
        byte = bytes([65 + i % 26])
        start = time.perf_counter_ns()
        send(byte)
        receive(byte)
        elapsed = (time.perf_counter_ns() - start) / 1e6
        if i >= 20:
            samples.append(elapsed)
    return summary(samples)


def main():
    with tempfile.TemporaryDirectory(prefix="gr-latency-") as directory:
        root = Path(directory)
        echo = root / "echo.py"
        echo.write_text(f"#!{sys.executable}\n"
                        "import os, tty\n"
                        "tty.setraw(0)\n"
                        "os.write(1, b'READY')\n"
                        "while True:\n"
                        "    b = os.read(0, 1)\n"
                        "    if not b: break\n"
                        "    os.write(1, b)\n")
        echo.chmod(0o700)
        master, slave = pty.openpty()
        direct = subprocess.Popen([echo], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)

        def direct_receive(expected):
            assert select.select([master], [], [], 5)[0], "PTY timed out"
            assert os.read(master, 4096) == expected

        try:
            direct_receive(b"READY")
            baseline = measure(lambda b: os.write(master, b), direct_receive)
        finally:
            direct.terminate()
            direct.wait(timeout=5)
            os.close(master)

        descriptor = root / "connection.json"
        env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=str(root / "config"),
                   XDG_STATE_HOME=str(root / "state"))
        with (root / "server.log").open("w") as log:
            server = subprocess.Popen([BINARY, "server", "--connection", descriptor, "--shell", echo],
                                      env=env, stdout=log, stderr=log)
        client = None
        try:
            for _ in range(100):
                if descriptor.exists():
                    break
                assert server.poll() is None, (root / "server.log").read_text()
                time.sleep(.05)
            client = PrivateClient(json.loads(descriptor.read_text()))
            pane = client.topology["panes"][0]["id"]
            client.send(dict(type="subscribe", sessions=[pane]))

            def receive(expected):
                while True:
                    kind, size = struct.unpack("<BI", client.read_exact(5))
                    data = client.read_exact(size)
                    if kind != 2:
                        continue
                    assert data[:4] == b"GRT2"
                    length = struct.unpack("<I", data[4:8])[0]
                    header = json.loads(data[8:8 + length])
                    payload = data[8 + length:]
                    if header.get("type") == "terminal" and expected in payload:
                        return

            def send(byte):
                header = json.dumps(dict(type="input", session=pane)).encode()
                data = b"GRT2" + struct.pack("<I", len(header)) + header + byte
                client.socket.sendall(b"\x02" + struct.pack("<I", len(data)) + data)

            receive(b"READY")
            core = measure(send, receive)
            print(json.dumps(dict(direct_pty=baseline, private_core=core,
                                  note="Debug server; includes Python client, PTY program and VT parsing; excludes Godot, GPU and display latency."), indent=2))
        finally:
            if client:
                client.socket.close()
            server.terminate()
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
