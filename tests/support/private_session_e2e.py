# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Private IPC and opt-in network clients exercise the same real session owner."""
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

from headless_remote_e2e import BINARY, Client

def local_socket(url, timeout=5):
    endpoint = url.removeprefix("ipc://")
    if os.name != "nt":
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(timeout)
        connection.connect(endpoint)
        return connection
    return WindowsPipe(endpoint, timeout)


class WindowsPipe:
    """Socket-shaped test transport for the production Windows named pipe."""
    def __init__(self, endpoint, timeout):
        import ctypes
        import msvcrt
        self.file = open(endpoint, "r+b", buffering=0)
        self.timeout = timeout
        self.handle = ctypes.c_void_p(msvcrt.get_osfhandle(self.file.fileno()))
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.PeekNamedPipe.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong,
                                             ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.c_void_p]

    def sendall(self, data):
        while data:
            written = self.file.write(data)
            if not written:
                raise EOFError("private pipe closed during write")
            data = data[written:]

    def recv(self, size):
        import ctypes
        deadline = time.monotonic() + self.timeout
        while True:
            available = ctypes.c_ulong()
            if not self.kernel.PeekNamedPipe(self.handle, None, 0, None, ctypes.byref(available), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if available.value:
                return self.file.read(min(size, available.value))
            if time.monotonic() >= deadline:
                raise TimeoutError("private pipe read timed out")
            time.sleep(.002)

    def close(self):
        self.file.close()


class PrivateClient:
    def __init__(self, descriptor, workspace="main", timeout=5):
        self.timeout = timeout
        self.socket = local_socket(descriptor["url"], timeout=timeout)
        self.sequence = 0
        self.frames = []
        self.send(dict(type="auth_local", version=1, token=descriptor["token"],
                       workspace=workspace, features=[]))
        self.until(lambda m: m.get("type") == "ready")
        self.topology = self.until(lambda m: m.get("type") == "topology")

    def send(self, value):
        data = json.dumps(value).encode()
        self.socket.sendall(b"\x01" + struct.pack("<I", len(data)) + data)

    def read_exact(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.socket.recv(n-len(data))
            if not chunk:
                raise EOFError("private connection closed")
            data.extend(chunk)
        return data

    def until(self, predicate):
        deadline = time.monotonic()+max(10, self.timeout)
        while time.monotonic() < deadline:
            header = self.read_exact(5)
            kind, size = struct.unpack("<BI", header)
            assert size <= 8*1024*1024
            data = self.read_exact(size)
            if kind == 2:
                self.frames.append(data)
            if kind == 1:
                message = json.loads(data)
                self.track(message)
                if predicate(message):
                    return message
        raise AssertionError("response timeout")

    def track(self, message):
        """Keep `topology` current: structure arrives whole, volatile pane
        fields (titles, foreground app, holds) as `pane_update` deltas."""
        if message.get("type") == "session_list":
            self.available_sessions = message["sessions"]
        elif message.get("type") == "topology":
            self.topology = message
        elif message.get("type") == "pane_update" and getattr(self, "topology", None):
            for key in ("panes", "tabs", "chromiums"):
                current = {item["id"]: item for item in self.topology.get(key, [])}
                for update in message.get(key, []):
                    if update["id"] in current:
                        current[update["id"]].update(update)

    def action(self, action, pane=-1, **params):
        self.sequence += 1
        self.send(dict(type=action, session=pane, request=self.sequence, **params))
        return self.until(lambda m: m.get("request") == self.sequence)

    def terminal(self):
        pending = bytearray()
        while True:
            if self.frames:
                kind, data = 2, self.frames.pop(0)
            else:
                kind, size = struct.unpack("<BI", self.read_exact(5))
                assert size <= 8*1024*1024
                data = self.read_exact(size)
            if kind != 2:
                continue
            assert data[:4] == b"GRT2"
            length = struct.unpack("<I", data[4:8])[0]
            header = json.loads(data[8:8+length])
            if header.get("type") == "terminal":
                tx = header["scene"]
                assert tx["offset"] == len(pending)
                pending.extend(data[8+length:])
                if tx["commit"]:
                    assert len(pending) == tx["total"]
                    return header, pending[:tx["total"] - tx["graphics_bytes"]]


def main():
    with tempfile.TemporaryDirectory(prefix="gr-private-") as directory:
        root = Path(directory)
        descriptor_path = root/"server.json"
        env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=str(root/"config"),
                   XDG_STATE_HOME=str(root/"state"))
        with (root/"server.log").open("w") as log:
            server = subprocess.Popen([BINARY, "server", "--connection", descriptor_path,
                                       "--shell", "/bin/sh"], env=env, stdout=log, stderr=log)
        local = remote = None
        try:
            for _ in range(100):
                if descriptor_path.exists(): break
                assert server.poll() is None, (root/"server.log").read_text()
                time.sleep(.05)
            descriptor = json.loads(descriptor_path.read_text())
            assert descriptor["remote"] is None
            assert descriptor["url"].startswith("ipc://")
            assert descriptor_path.stat().st_mode & 0o077 == 0
            if shutil.which("lsof"):
                listeners = subprocess.run(["lsof", "-nP", "-a", "-p", str(server.pid),
                                           "-iTCP", "-sTCP:LISTEN"], capture_output=True)
                assert listeners.returncode == 1 and not listeners.stdout, listeners.stdout
            local = PrivateClient(descriptor)
            pane = local.topology["panes"][0]["id"]
            assert local.action("font_size", pane, size=23)["type"] == "ack"
            assert local.action("font_size", pane, size=0)["type"] == "error"
            assert local.action("font_size", pane, size=73)["type"] == "error"
            assert local.action("text", pane, text="printf 'shared_core_marker\\n'\n")["type"] == "ack"
            opened = local.action("remote_access", enabled=True, address="127.0.0.1:0")
            assert opened["type"] == "ack", opened
            settings = local.action("auth_settings")
            assert settings["result"]["connection_file"] == str(descriptor_path)
            assert settings["result"]["remote"] == opened["result"]
            address_text = opened["result"]["url"].removeprefix("ws://")
            again = local.action("remote_access", enabled=True, address=address_text)
            assert again["type"] == "ack" and again["result"] == opened["result"], again
            rejected = local.action("remote_access", enabled=True, address="not-an-address:0")
            assert rejected["type"] == "error"
            assert local.action("auth_settings")["result"]["remote"] == opened["result"]
            remote = Client(dict(opened["result"], local=descriptor["local"]))
            assert remote.topology["panes"][0]["id"] == pane
            remote.has_output(pane, "shared_core_marker")
            remote.action("remote_access", pane, request=900, enabled=False)
            remote.until(lambda: any(m.get("request") == 900 for m in remote.messages))
            assert next(m for m in remote.messages if m.get("request") == 900)["type"] == "error"
            address = opened["result"]["url"].removeprefix("ws://").split(":")
            # A TCP peer that has not sent HTTP bytes is still part of sharing
            # and must be revoked with authenticated clients.
            silent = socket.create_connection((address[0], int(address[1])))
            silent.settimeout(.5)
            time.sleep(.05)
            assert local.action("remote_access", enabled=False)["type"] == "ack"
            with silent:
                assert silent.recv(1) == b"", "Unfinished remote handshake survived revocation"
            address = opened["result"]["url"].removeprefix("ws://").split(":")
            with socket.socket() as check:
                assert check.connect_ex((address[0],int(address[1]))) != 0
            assert json.loads(descriptor_path.read_text())["remote"] is None
            # Explicit wildcard/interface binds are supported, not restricted
            # to loopback. Clients dial a concrete address, not 0.0.0.0.
            bind_ip = os.environ.get("GRAFFITTY_TEST_BIND_ADDRESS", "0.0.0.0")
            shared = local.action("remote_access", enabled=True, address=f"{bind_ip}:0")
            assert shared["type"] == "ack", shared
            assert shared["result"]["url"].startswith(f"ws://{bind_ip}:"), shared
            dial = dict(shared["result"], local=descriptor["local"])
            if bind_ip == "0.0.0.0":
                dial["url"] = dial["url"].replace("0.0.0.0", "127.0.0.1", 1)
            bound_client = Client(dial)
            try:
                assert bound_client.topology["panes"][0]["id"] == pane
            finally:
                bound_client.ws.close()
            assert local.action("remote_access", enabled=False)["type"] == "ack"
            assert local.action("text", pane, text="printf 'still_local\\n'\n")["type"] == "ack"
            assert local.action("create", pane, kind="pane")["type"] == "ack"
            # The server must continue parsing without any attached renderer.
            assert local.action("text", pane, text="sleep .2; printf 'while_%s\\n' detached\n")["type"] == "ack"
            local.socket.close()
            remote.ws.close()
            remote = None
            time.sleep(.4)
            local = PrivateClient(json.loads(descriptor_path.read_text()))
            assert len(local.topology["panes"]) == 2
            assert all(p["font_size"] == 23 for p in local.topology["panes"])
            local.send(dict(type="subscribe", sessions=[pane]))
            header, payload = local.terminal()
            assert header["scene"]["snapshot"] and header["scene"]["commit"]
            assert b"while_detached" in payload, payload
            # Output advances the scene via deltas or a coalesced checkpoint.
            # Multiple owner revisions may complete before the consumer reads.
            revision = header["scene"]["revision"]
            local.action("text", pane, text="printf 'delta_%s\\n' marker\n")
            received = bytearray()
            while b"delta_marker" not in received:
                header, payload = local.terminal()
                tx = header["scene"]
                assert tx["revision"] > revision, tx
                assert tx["snapshot"] or tx["base"] == revision, tx
                revision = tx["revision"]
                received.extend(payload)
            # A bad local capability must never create a workspace.
            bad = socket.socket(socket.AF_UNIX)
            bad.settimeout(3)
            bad.connect(descriptor["url"].removeprefix("ipc://"))
            data=json.dumps(dict(type="auth_local",version=1,token="wrong")).encode()
            bad.sendall(b"\x01"+struct.pack("<I",len(data))+data)
            assert bad.recv(1) == b""
            bad.close()
            print("PASS: no default TCP listener; shared local/remote PTY; local-only access toggle; revocation; detached output retained; reconnect checkpoint and current scene transactions; capability rejection")
        finally:
            if local: local.socket.close()
            if remote: remote.ws.close()
            server.terminate()
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
