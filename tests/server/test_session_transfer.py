"""Real numbered-session allocation and atomic transfer of live PTYs."""

import json
import os
import sys
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support", "tools")]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient, local_socket


class Peer(PrivateClient):
    def __init__(self, descriptor, workspace="main", new=False, fallback=False, timeout=5):
        self.timeout = timeout
        self.socket = local_socket(descriptor["url"], timeout=timeout)
        self.sequence = 0
        self.frames = []
        self.send(
            dict(
                type="auth_local",
                version=1,
                token=descriptor["token"],
                workspace=workspace,
                new_session=new,
                workspace_fallback=fallback,
                features=[],
            )
        )
        self.workspace = self.until(lambda m: m.get("type") == "ready")["workspace"]
        self.topology = self.until(lambda m: m.get("type") == "topology")

    def sync(self):
        self.sequence += 1
        self.send(dict(type="sync", request=self.sequence))
        while True:
            message = self.until(
                lambda m: (
                    m.get("type") == "topology" or m.get("request") == self.sequence
                )
            )
            if message.get("request") == self.sequence:
                break
            self.topology = message
        return self.topology


class SessionTransferTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot is unavailable")
    def test_sessions_panel_routes_live_tabs_and_cancels_hover_without_closing_sessions(self):
        from check_godot import failed
        with tempfile.TemporaryDirectory(prefix="gft-panel-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh"):
                result = subprocess.run([
                    "godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                    "--script", "res://tests/session_panel_transfer_smoke.gd",
                ], env=env, capture_output=True, text=True, timeout=75)
                output = result.stdout + result.stderr
                self.assertFalse(failed(result.returncode, output), output)
                self.assertIn("SESSION_PANEL_TRANSFER_PASS", output)

    @unittest.skipUnless(shutil.which("godot"), "Godot is unavailable")
    def test_remote_sessions_panel_transfers_live_tabs_and_panes(self):
        from check_godot import failed
        from test_terminal_scene import Owner
        with Owner(network=True) as owner:
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(owner.path / "frontend" / kind.lower())
            env["GRAFFITTY_TEST_REMOTE_DESCRIPTOR"] = str(owner.descriptor)
            result = subprocess.run([
                "godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                "--script", "res://tests/session_panel_transfer_smoke.gd",
            ], env=env, capture_output=True, text=True, timeout=75)
            output = result.stdout + result.stderr
            self.assertFalse(failed(result.returncode, output), output)
            self.assertIn("SESSION_PANEL_TRANSFER_PASS", output)

    def test_network_transfer_creates_listed_session_and_preserves_processes(self):
        from test_terminal_scene import Owner, Peer as NetworkPeer

        with Owner(network=True) as owner:
            descriptor = json.loads(owner.descriptor.read_text())
            remote = NetworkPeer(descriptor, network=True)
            clients = []
            sequence = 0

            def action(action_type, **params):
                nonlocal sequence
                sequence += 1
                remote.send(type=action_type, request=sequence, **params)
                while True:
                    message, _ = remote.read()
                    if message.get("request") == sequence:
                        return message

            try:
                source = Peer(descriptor["local"])
                clients.append(source)
                original = source.topology["panes"][0]
                created = action("create", kind="tab")["created"]
                before = source.sync()
                moved_pane = next(p for p in before["panes"] if p["id"] == created)
                # The network path retains source/destination validation.
                self.assertEqual(action("session_transfer", tab=original["tab"],
                                        destination="missing")["type"], "error")
                result = action("session_transfer", tab=moved_pane["tab"])
                self.assertNotEqual(result.get("type"), "error", result)
                self.assertNotEqual(result["workspace"], source.workspace)
                moved = Peer(descriptor["local"], result["workspace"])
                clients.append(moved)
                self.assertEqual([(p["id"], p["pid"]) for p in moved.topology["panes"]],
                                 [(created, moved_pane["pid"])])
                topology = source.sync()
                self.assertEqual([p["id"] for p in topology["panes"]], [original["id"]])
                self.assertIn(result["workspace"], [s["id"] for s in source.available_sessions])
                self.assertEqual(action("session_transfer", tab=moved_pane["tab"])["type"], "error")
                # The new session is attachable over the same network connection.
                self.assertNotEqual(action("session_switch", name=result["workspace"]).get("type"), "error")
                self.assertIsNone(owner.process.poll())
            finally:
                remote.socket.close()
                for client in clients:
                    client.socket.close()

    def test_numbered_sessions_transfer_live_shells_and_reject_stale_targets(self):
        with tempfile.TemporaryDirectory(prefix="gr-session-transfer-") as tmp:
            directory = Path(tmp)
            env = {
                k: v
                for k, v in os.environ.items()
                if not k.startswith(("GRAFFITTY_",))
            }
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                local = json.loads(owner.descriptor.read_text())["local"]
                clients = []

                def peer(*args, **kwargs):
                    value = Peer(local, *args, **kwargs)
                    clients.append(value)
                    return value

                try:
                    first, second = peer(new=True), peer(new=True)
                    self.assertEqual((first.workspace, second.workspace), ("$1", "$2"))
                    original = first.topology["panes"][0]
                    other = second.topology["panes"][0]
                    created = first.action("create", kind="tab")["created"]
                    split = first.action("create", created, kind="pane")["created"]
                    before = first.sync()
                    panes = {p["id"]: p for p in before["panes"] if p["tab"] == created}
                    self.assertEqual(set(panes), {created, split})
                    marker = "transfer-retained-output"
                    first.action("text", created, text=f"printf '{marker}\\n'\n")
                    # Foreign source, unknown destination and stale destination
                    # witnesses all fail before changing membership.
                    for client, params in (
                        (second, dict(tab=created)),
                        (first, dict(tab=created, destination="missing")),
                        (
                            first,
                            dict(tab=created, destination="2", destination_tab=created),
                        ),
                    ):
                        self.assertEqual(
                            client.action("session_transfer", **params)["type"], "error"
                        )
                    self.assertEqual(
                        {p["id"] for p in first.sync()["panes"]},
                        {original["id"], created, split},
                    )
                    layout = before["workspace_state"]["layout"]["tabs"][str(created)]
                    result = first.action("session_transfer", tab=created)
                    self.assertEqual(result["workspace"], "$3")
                    self.assertFalse(result["source_empty"])
                    moved = peer("3")
                    self.assertEqual(
                        moved.topology["workspace_state"]["layout"]["tabs"][
                            str(created)
                        ],
                        layout,
                    )
                    self.assertEqual(
                        {p["id"]: p["pid"] for p in moved.topology["panes"]},
                        {i: p["pid"] for i, p in panes.items()},
                    )
                    self.assertEqual(
                        [p["id"] for p in first.sync()["panes"]], [original["id"]]
                    )
                    moved.send(dict(type="history", session=created))
                    history = moved.until(lambda m: m.get("type") == "history")["text"]
                    self.assertIn(marker, history)
                    # The same tab can then join an existing numbered session.
                    result = moved.action(
                        "session_transfer",
                        tab=created,
                        destination="2",
                        destination_tab=other["tab"],
                    )
                    self.assertTrue(result["source_empty"])
                    self.assertEqual(
                        moved.until(lambda m: m.get("type") == "session_closed")[
                            "workspace"
                        ],
                        "$3",
                    )
                    received = second.sync()
                    self.assertEqual(
                        {p["id"] for p in received["panes"]},
                        {other["id"], created, split},
                    )
                    self.assertNotIn("$3", [s["id"] for s in second.available_sessions])
                    self.assertEqual(
                        first.action("text", created, text="should-not-route\n")[
                            "type"
                        ],
                        "error",
                    )
                    for pane in received["panes"]:
                        os.kill(pane["pid"], 0)
                        if pane["id"] in panes:
                            self.assertEqual(pane["pid"], panes[pane["id"]]["pid"])
                    # Explicit reattachment preserves a session; the next new
                    # window receives a new stable ID without reusing a deleted one.
                    attached = peer("2")
                    self.assertEqual(len(attached.topology["panes"]), 3)
                    self.assertEqual(peer(new=True).workspace, "$4")
                    self.assertIsNone(owner.process.poll())
                finally:
                    for client in clients:
                        client.socket.close()

    def test_vanished_remembered_session_falls_back_to_the_oldest(self):
        with tempfile.TemporaryDirectory(prefix="gr-session-fallback-") as tmp:
            directory = Path(tmp)
            env = {
                k: v
                for k, v in os.environ.items()
                if not k.startswith(("GRAFFITTY_",))
            }
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                local = json.loads(owner.descriptor.read_text())["local"]
                clients = []

                def peer(*args, **kwargs):
                    value = Peer(local, *args, **kwargs)
                    clients.append(value)
                    return value

                try:
                    self.assertEqual(
                        (peer(new=True).workspace, peer(new=True).workspace), ("$1", "$2")
                    )
                    # An existing remembered session is joined as requested.
                    self.assertEqual(peer("2", fallback=True).workspace, "$2")
                    # A vanished one joins the oldest session, not a new empty one.
                    gone = peer("gone", fallback=True)
                    self.assertEqual(gone.workspace, "$1")
                    self.assertNotIn("gone", [s["name"] for s in gone.available_sessions])
                    # Explicit names keep creating sessions without the flag.
                    fresh = peer("fresh")
                    self.assertEqual(fresh.workspace, "$3")
                    self.assertEqual(next(s for s in fresh.available_sessions if s["id"] == "$3")["name"], "fresh")
                    self.assertIsNone(owner.process.poll())
                finally:
                    for client in clients:
                        client.socket.close()

    def test_starting_frontend_resumes_the_session_a_frontend_showed_last(self):
        with tempfile.TemporaryDirectory(prefix="gr-session-resume-") as tmp:
            directory = Path(tmp)
            env = {
                k: v
                for k, v in os.environ.items()
                if not k.startswith(("GRAFFITTY_",))
            }
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                local = json.loads(owner.descriptor.read_text())["local"]
                clients = []

                def peer(*args, **kwargs):
                    value = Peer(local, *args, **kwargs)
                    clients.append(value)
                    return value

                def show(client):
                    client.send(dict(type="frontend_register", generation=1, request="show"))
                    client.until(lambda m: m.get("request") == "show")

                try:
                    # Nothing to resume: a fresh unnamed session, never a stale
                    # name revived or an error for a vanished `$N`.
                    first = peer("", fallback=True)
                    self.assertEqual(first.workspace, "$1")
                    stale = peer("$7", fallback=True)
                    self.assertEqual(stale.workspace, "$1")
                    second = peer(new=True)
                    self.assertEqual(second.workspace, "$2")
                    # Without a frontend's view the oldest session is resumed.
                    self.assertEqual(peer("", fallback=True).workspace, "$1")
                    # The session a frontend shows is the one a starting frontend resumes.
                    show(second)
                    self.assertEqual(peer("", fallback=True).workspace, "$2")
                    show(first)
                    self.assertEqual(peer("", fallback=True).workspace, "$1")
                    # A new session is still available on request.
                    self.assertEqual(peer(new=True).workspace, "$3")
                    second.sync()
                    names = [s["name"] for s in second.available_sessions]
                    self.assertNotIn("$7", names)
                    self.assertIsNone(owner.process.poll())
                finally:
                    for client in clients:
                        client.socket.close()


if __name__ == "__main__":
    unittest.main()
