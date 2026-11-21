# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real standalone servers, PTYs and native multi-server Godot clients.
Run: mise exec -- uv run tests/support/headless_remote_e2e.py
"""

import json
import os
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

import websocket

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(
    os.environ.get(
        "GRAFFITTY_TEST_SERVER",
        ROOT / "target/debug/gft",
    )
)


class Client:
    def __init__(self, descriptor, workspace="main", receive_buffer=0, chromium_video=None, chromium_image_format="png", chromium_stream=None):
        # Exercise delayed HTTP handshakes after TCP accept (macOS accepted
        # sockets can inherit the listener's nonblocking mode).
        endpoint = urlsplit(descriptor["url"])
        stream = socket.create_connection((endpoint.hostname, endpoint.port), timeout=5)
        if receive_buffer:
            stream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
        time.sleep(0.04)
        self.ws = websocket.create_connection(
            descriptor["url"], timeout=5, socket=stream
        )
        self.ws.send(
            json.dumps(
                {
                    # Loopback tools present the local capability; remote
                    # clients must complete the encrypted OPAQUE login.
                    "type": "auth_local",
                    "version": 1,
                    "token": descriptor["local"]["token"],
                    "workspace": workspace,
                    **({"chromium_stream": chromium_stream} if chromium_stream is not None else {}),
                    **({"chromium_video": chromium_video} if chromium_video is not None else {}),
                    **({"chromium_image_format": chromium_image_format} if chromium_image_format else {}),
                }
            )
        )
        self.topology = None
        self.frames = {}
        self.payloads = {}
        self.largest_packet = 0
        self.messages = []
        self.until(lambda: self.topology is not None)

    def receive(self):
        value = self.ws.recv()
        if isinstance(value, bytes):
            self.largest_packet = max(self.largest_packet, len(value))
            assert value[:4] == b"GRT2"
            size = struct.unpack("<I", value[4:8])[0]
            header = json.loads(value[8 : 8 + size])
            if header.get("type") == "chromium" and "frame" in header:
                self.ws.send(json.dumps({"type": "chromium_ack", "session": header["session"], "frame": header["frame"]}))
            self.frames[header["session"]] = header
            self.payloads[header["session"]] = value[8 + size:]
        else:
            value = json.loads(value)
            if value["type"] == "topology":
                self.topology = value
            elif value["type"] == "pane_update" and getattr(self, "topology", None):
                # Titles and foreground apps arrive as deltas between structural topologies.
                for key in ("panes", "tabs", "chromiums"):
                    current = {item["id"]: item for item in self.topology.get(key, [])}
                    for update in value.get(key, []):
                        if update["id"] in current:
                            current[update["id"]].update(update)
            self.messages.append(value)

    def until(self, predicate):
        deadline = time.monotonic() + 10
        while not predicate() and time.monotonic() < deadline:
            self.receive()
        assert predicate(), self.messages[-5:]

    def action(self, action, pane=-1, **values):
        self.ws.send(json.dumps(dict(type=action, session=pane, **values)))

    def text(self, pane, text):
        header = json.dumps({"type": "input", "session": pane}).encode()
        self.ws.send_binary(
            b"GRT2" + struct.pack("<I", len(header)) + header + text.encode()
        )

    def history(self, pane):
        self.messages.clear()
        self.action("history", pane)
        self.until(lambda: any(m["type"] == "history" for m in self.messages))
        return next(m["text"] for m in self.messages if m["type"] == "history")

    def has_output(self, pane, expected):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if expected in self.history(pane):
                return
            time.sleep(0.05)
        raise AssertionError(f"missing output {expected}")


def main():
    with tempfile.TemporaryDirectory(prefix="gr-headless-") as tmp:
        tmp = Path(tmp)
        servers = []
        clients = []
        try:
            descriptors = []
            for n in range(3):
                path = tmp / f"server{n}.json"
                env = dict(
                    os.environ,
                    SHELL="/bin/sh",
                    GRAFFITTY_CODEX_CONTEXT="stale-local-context",
                )
                env.pop("DISPLAY", None)
                env.pop("WAYLAND_DISPLAY", None)
                process = subprocess.Popen(
                    [BINARY, "server", "--listen", "127.0.0.1:0", "--connection", path, "--auth-file", tmp / "auth.json"],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=(tmp / f"server{n}.log").open("w"),
                )
                servers.append(process)
                for _ in range(100):
                    if path.exists():
                        break
                    assert process.poll() is None, (tmp / f"server{n}.log").read_text()
                    time.sleep(0.05)
                descriptor = json.loads(path.read_text())
                assert path.stat().st_mode & 0o777 == 0o600
                status = subprocess.check_output(
                    [BINARY, "server", "--connection", path, "--auth-file", tmp / "auth.json", "--status"]
                )
                assert json.loads(status) == descriptor
                descriptors.append(descriptor)
            a = Client(descriptors[0], "alpha")
            clients.append(a)
            b = Client(descriptors[0], "beta")
            clients.append(b)
            c = Client(descriptors[1], "alpha")
            clients.append(c)
            a_id = a.topology["panes"][0]["id"]
            b_id = b.topology["panes"][0]["id"]
            b_columns = b.topology["panes"][0]["columns"]
            c_id = c.topology["panes"][0]["id"]
            pid = a.topology["panes"][0]["pid"]
            a.until(lambda: any(
                m.get("type") == "resources" and any(
                    sample["snapshot"].get("cpu_valid")
                    and sample["snapshot"].get("memory_current", 0) > 0
                    for sample in m["samples"]
                ) for m in a.messages
            ))
            samples = [sample for message in a.messages if message.get("type") == "resources"
                       for sample in message["samples"]]
            assert all(sample["session"] == a_id and sample["snapshot"]["root_pid"] == pid
                       for sample in samples), "resource packets must remain workspace-scoped"
            assert a_id != b_id and a_id == c_id, (
                "exercise colliding IDs across servers"
            )
            a.action("history", b_id)
            a.until(lambda: any(m["type"] == "error" for m in a.messages))
            a.text(a_id, "printf '\\033[31m한글 é\\033[0m\\n'\r")
            a.has_output(a_id, "한글 é")
            a.text(
                a_id,
                'printf "__CAP__%s__END__\\n" "${GRAFFITTY_CODEX_CONTEXT-unset}"\r',
            )
            a.has_output(a_id, "__CAP__unset__END__")
            assert "한글" not in b.history(b_id)
            a.action("resize", a_id, columns=65, rows=18)
            a.until(lambda: a.topology["panes"][0]["columns"] == 65)
            a.text(a_id, "stty size\r")
            a.has_output(a_id, "18 65")
            assert b.topology["panes"][0]["columns"] == b_columns
            a.text(a_id, "sleep 30\r")
            time.sleep(0.1)
            a.text(a_id, "\x03printf 'CTRL_OK\\n'\r")
            a.has_output(a_id, "CTRL_OK")
            a.text(a_id, "sleep 0.3; printf 'DETACHED_OK\\n'\r")
            a.ws.close()
            time.sleep(0.5)
            observer = Client(descriptors[0], "alpha")
            clients.append(observer)
            assert observer.topology["panes"][0]["pid"] == pid
            observer.has_output(a_id, "DETACHED_OK")
            observer.action("create", a_id, kind="pane")
            observer.until(lambda: len(observer.topology["panes"]) == 2)
            created = next(
                p["id"] for p in observer.topology["panes"] if p["id"] != a_id
            )
            observer.action("close", created)
            observer.until(lambda: len(observer.topology["panes"]) == 1)
            # A slow observer must receive queued bytes, not disconnect on
            # the first nonblocking write. Full colored grids exceed TCP buffers.
            bulk = Client(descriptors[1], "bulk", receive_buffer=4096)
            clients.append(bulk)
            bulk_id = bulk.topology["panes"][0]["id"]
            bulk.action("resize", bulk_id, columns=300, rows=150)
            bulk.until(lambda: bulk.topology["panes"][0]["columns"] == 300)
            bulk.text(
                bulk_id,
                'awk \'BEGIN {for(i=0;i<140;i++){for(j=0;j<290;j++) printf "\\033[48;2;%d;%d;0mX",i,j%256; printf "\\r\\n"}}\'\r',
            )
            time.sleep(0.5)
            bulk.action("subscribe", sessions=[bulk_id])
            time.sleep(0.25)
            bulk.until(lambda: bulk.largest_packet > 65536)
            assert bulk.history(bulk_id)

            # Notifications are independent of screen subscriptions and retain
            # the authoritative source identity for click-to-focus routing.
            observer.text(a_id, "printf '\\033]9;REMOTE_NOTIFY_BODY\\007'\r")
            observer.until(
                lambda: any(
                    m.get("type") == "notification"
                    and m.get("body") == "REMOTE_NOTIFY_BODY"
                    and m.get("session") == a_id
                    for m in observer.messages
                )
            )

            # A busy shell ignoring HUP must not hang pane closure or daemon
            # shutdown while the bounded PTY output queue is full.
            closing = Client(descriptors[0], "closing")
            clients.append(closing)
            closing_id = closing.topology["panes"][0]["id"]
            closing.text(
                closing_id, "trap '' HUP; while :; do printf 'busy output\\n'; done\r"
            )
            time.sleep(0.15)
            closing.action("close", closing_id)
            # Closing the last pane ends the workspace.
            closing.until(lambda: not closing.topology["panes"]
                          or any(m.get("type") == "session_closed" for m in closing.messages))
            assert "DETACHED_OK" in observer.history(a_id)

            # Authentication failure must expose no topology/token, and the
            # plaintext temporary-password login no longer exists.
            for attempt in [
                {"type": "auth", "version": 1, "token": descriptors[0]["token"]},
                {"type": "auth_local", "version": 1, "token": "wrong"},
            ]:
                bad = websocket.create_connection(descriptors[0]["url"], timeout=5)
                bad.send(json.dumps(attempt))
                assert bad.recv() in ["", b""], attempt
                bad.close()
            print(
                "PASS standalone PTYs, Unicode, workspace isolation, resize, Ctrl-C, detach/reconnect, create/close, auth",
                flush=True,
            )
            if os.environ.get("GRAFFITTY_TEST_BACKEND_ONLY"):
                return
            # This image predates the native client: its first frame must fetch
            # authoritative pixels/placements, not depend on a live upload.
            import base64

            image_file = tmp / "tty-graphics-protocol-remote.png"
            image_file.write_bytes(
                base64.b64decode(
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
                )
            )
            encoded_path = base64.b64encode(str(image_file).encode()).decode()
            observer.text(
                a_id,
                f"printf '\\033[2J\\033[H\\033_Ga=T,t=t,f=100,i=9001,p=1,c=4,r=2,q=2;{encoded_path}\\033\\\\'; printf 'IMAGE_SEEDED\\n'\r",
            )
            observer.has_output(a_id, "IMAGE_SEEDED")
            observer.until(lambda: not image_file.exists())
            config = tmp / "connections.json"
            config.write_text(
                json.dumps(
                    {
                        "connections": [
                            dict(descriptors[0], workspace="alpha", name="A"),
                            dict(descriptors[2], workspace="alpha", name="B"),
                            dict(descriptors[1], workspace="alpha", name="C"),
                        ]
                    }
                )
            )
            with Path("/tmp/graffitty-headless-client-e2e.log").open("w") as log:
                result = subprocess.run(
                    [
                        "godot",
                        "--headless",
                        "--path",
                        str(ROOT / "frontends/godot/project"),
                        "--script",
                        "res://tests/headless_remote_client_e2e.gd",
                        "--",
                        f"--remote-connections={config}",
                    ],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=120,
                    check=False,
                )
            logs = Path("/tmp/graffitty-headless-client-e2e.log").read_text()
            assert result.returncode == 0 and "HEADLESS REMOTE PASS" in logs, logs[
                -10000:
            ]
            print(
                "PASS native multi-server client (see /tmp/graffitty-headless-client-e2e.log)",
                flush=True,
            )
        finally:
            for c in clients:
                c.ws.close()
            for server in servers:
                server.terminate()
            for server in servers:
                server.wait(timeout=10)


if __name__ == "__main__":
    main()
