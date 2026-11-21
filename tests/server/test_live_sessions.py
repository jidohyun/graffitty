"""Real shared-server session commands, help routing, and PTY lifecycle."""
import json
import os
from pathlib import Path
import socket
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient

CLI = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/release/gft"))

class LiveSessionTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "PTY process-survival checks require POSIX")
    def test_close_server_is_local_only_and_ends_attached_and_detached_sessions(self):
        from test_terminal_scene import Owner, Peer as NetworkPeer
        from test_session_transfer import Peer

        # macOS holder sockets must fit SUN_LEN, including the evidence path.
        with (
            tempfile.TemporaryDirectory(prefix="gfc-", dir="/tmp" if sys.platform == "darwin" else None) as evidence,
            patch.dict(os.environ, {"GRAFFITTY_SCENE_EVIDENCE": os.environ.get("GRAFFITTY_SCENE_EVIDENCE", evidence)}),
            Owner(network=True) as owner,
            Owner(network=True) as remote_owner,
        ):
            descriptor = json.loads(owner.descriptor.read_text())
            local = Peer(descriptor["local"])
            attached = Peer(descriptor["local"], "attached", new=True)
            detached = Peer(descriptor["local"], "detached", new=True)
            pids = [peer.topology["panes"][0]["pid"] for peer in (local, attached, detached)]
            detached.socket.close()
            network = NetworkPeer(descriptor, network=True)
            try:
                # Even a loopback WebSocket authenticated with the local token
                # cannot invoke the server-wide action.
                network.send(type="close_server", request=1)
                while True:
                    denied, _ = network.read()
                    if denied.get("request") == 1: break
                self.assertEqual(denied.get("type"), "error", denied)
                self.assertEqual(denied.get("error", {}).get("code"), "forbidden", denied)
                self.assertIsNone(owner.process.poll())
                for pid in pids: os.kill(pid, 0)
                reply = local.action("close_server")
                self.assertTrue(reply.get("server_closed"), reply)
                self.assertEqual(attached.until(lambda m: m.get("type") == "session_closed")["workspace"], attached.workspace)
                self.assertEqual(owner.process.wait(timeout=10), 0)
                self.assertFalse(owner.descriptor.exists())
                deadline = time.monotonic() + 5
                for pid in pids:
                    while True:
                        try: os.kill(pid, 0)
                        except ProcessLookupError: break
                        self.assertLess(time.monotonic(), deadline, "Closed server left a PTY alive")
                        time.sleep(.03)
                self.assertIsNone(remote_owner.process.poll())
                remote_owner.output(b"REMOTE_SURVIVED_LOCAL_SERVER_CLOSE")
            finally:
                local.socket.close()
                attached.socket.close()
                network.socket.close()

    def test_sessions_are_independent_and_commands_share_help_group(self):
        with tempfile.TemporaryDirectory(prefix="gr-live-sessions-") as tmp:
            directory = Path(tmp).resolve()
            env = {k:v for k,v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            first_cwd = directory / "first"; first_cwd.mkdir()
            second_cwd = directory / "second"; second_cwd.mkdir()
            def run(*args, ok=True):
                result = subprocess.run([CLI, *args], env=env, cwd=first_cwd, capture_output=True, text=True, timeout=20)
                if ok: self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else: self.assertNotEqual(result.returncode, 0)
                return result.stdout
            with PrivateServer(env, directory, "/bin/sh") as owner:
                self.assertEqual(json.loads(run("session", "list", "--json")), [])
                work_id = run("session", "new", "-d", "-s", "work", "-c", str(second_cwd)).strip()
                auto_id = run("session", "new", "-d").strip()
                self.assertEqual(work_id, "$1")
                self.assertEqual(auto_id, "$2")
                run("session", "new", "-d", "-s", "work", ok=False)
                run("session", "new", "-d", "-s", "bad:name", ok=False)
                expected = json.loads(run("session", "list", "--json"))
                self.assertEqual({s["name"] for s in expected}, {"work", None})
                self.assertEqual({s["automatic_name"] for s in expected}, {"first", "second"})
                self.assertTrue(all(s["panes"] == s["windows"] == 1 for s in expected))
                self.assertTrue(all(s["agents"] == [] for s in expected), expected)
                local = json.loads(owner.descriptor.read_text())["local"]
                client = PrivateClient(local, "work")
                other = PrivateClient(local, auto_id)
                try:
                    pane = client.topology["panes"][0]
                    self.assertEqual(pane["id"], 1)
                    other_pane = other.topology["panes"][0]
                    for peer, info, cwd in ((client, pane, second_cwd), (other, other_pane, first_cwd)):
                        peer.action("resize", info["id"], columns=300, rows=24)
                        peer.action("text", info["id"], text="printf 'LIVE_%s_CWD=%s\\n' SESSION \"$PWD\"\n")
                        deadline = time.monotonic() + 5
                        while True:
                            peer.send({"type":"history", "session":info["id"]})
                            history = peer.until(lambda m:m.get("type") == "history")["text"]
                            if f"LIVE_SESSION_CWD={cwd}" in history: break
                            self.assertLess(time.monotonic(), deadline, history)
                            time.sleep(.03)
                    # Session descriptors list every session's agents, so clients
                    # show agents of sessions they are not attached to.
                    client.action("text", pane["id"], text="printf '\\033]7501;state=working:app=codex:msg=UmVmYWN0b3I=\\033\\\\'\n")
                    deadline = time.monotonic() + 5
                    while True:
                        sessions = {s["name"]: s for s in json.loads(run("session", "list", "--json"))}
                        if sessions["work"]["agents"]: break
                        self.assertLess(time.monotonic(), deadline, sessions)
                        time.sleep(.05)
                    [agent] = sessions["work"]["agents"]
                    self.assertEqual(agent["pane"], pane["id"])
                    self.assertEqual(agent["program"], {"state":"working", "app":"codex", "title":"", "msg":"Refactor"})
                    self.assertEqual(sessions[None]["agents"], [])
                    # attach-session reaches the real existence check, then
                    # inspect the GUI launcher arguments without opening a window.
                    shim = directory / "bin"; shim.mkdir()
                    captured = directory / "launch.json"
                    (shim / "mise").write_text(f'#!{sys.executable}\nimport json,sys\nopen({str(captured)!r},"w").write(json.dumps(sys.argv[1:]))\n')
                    (shim / "mise").chmod(0o755)
                    env["PATH"] = str(shim) + os.pathsep + env["PATH"]
                    for spelling in ("attach",):
                        run("session", spelling, "-t", "work")
                        args = json.loads(captured.read_text())
                        self.assertIn("--workspace=work", args)
                        self.assertIn("--attach-session", args)
                    run("session", "attach", "-t", "missing", ok=False)
                    run("session", "has", "-t", "work")
                    # A save from inside a pane captures every session, not
                    # only the caller's, so a full restore loses none.
                    pane_env = dict(env, GRAFFITTY_SOCKET=local["url"], GRAFFITTY_CHECKPOINT_DIR=str(directory / "checkpoints"))
                    saved = subprocess.run([CLI, "checkpoint", "save"], env=pane_env, cwd=first_cwd, capture_output=True, text=True, timeout=20)
                    self.assertEqual(saved.returncode, 0, saved.stdout + saved.stderr)
                    document = json.loads(Path(json.loads(saved.stdout)["path"]).read_text())
                    self.assertEqual(sorted(w["workspace"] for w in document["windows"]), sorted([work_id, auto_id]))
                    # A fresh server has no older-build holders draining.
                    with socket.socket(socket.AF_UNIX) as api:
                        api.connect(local["url"].removeprefix("ipc://"))
                        api.sendall(json.dumps({"version":1,"id":"status","token":local["token"],"method":"server.status","params":{}}).encode()+b"\n")
                        status = json.loads(api.makefile("rb").readline())
                        self.assertEqual(status["result"]["draining_holders"], 0, status)
                        self.assertEqual(status["result"]["draining_terminals"], 0, status)
                    # A pane capability must not administer other sessions.
                    with socket.socket(socket.AF_UNIX) as api:
                        api.connect(local["url"].removeprefix("ipc://"))
                        api.sendall(json.dumps({"version":1,"id":"denied","token":"invalid","method":"session.kill","params":{"name":"work"}}).encode()+b"\n")
                        self.assertEqual(json.loads(api.makefile("rb").readline())["error"]["code"], "forbidden")
                    # Real sibling pane cwds must contribute to the common root.
                    left = second_cwd / "src"
                    right = second_cwd / "tests"
                    left.mkdir(); right.mkdir()
                    client.action("text", pane["id"], text=f"cd {shlex.quote(str(left))}\n")
                    deadline = time.monotonic() + 5
                    while True:
                        listing = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                        if listing["automatic_name"] == "src": break
                        self.assertLess(time.monotonic(), deadline, listing)
                        time.sleep(.05)
                    sibling = client.action("create", pane["id"], kind="pane")["created"]
                    client.action("text", sibling, text=f"cd {shlex.quote(str(right))}\n")
                    deadline = time.monotonic() + 5
                    while True:
                        listing = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                        if listing["automatic_name"] == "second": break
                        self.assertLess(time.monotonic(), deadline, listing)
                        time.sleep(.05)
                    self.assertEqual(listing["panes"], 2)
                    # Directory-derived labels track the real shells, including home.
                    for terminal in (pane["id"], sibling):
                        client.action("text", terminal, text='cd "$HOME"\n')
                    deadline = time.monotonic() + 5
                    while True:
                        listing = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                        if listing["automatic_name"] == "~": break
                        self.assertLess(time.monotonic(), deadline, listing)
                        time.sleep(.05)
                    self.assertEqual(listing["name"], "work")
                    for terminal in (pane["id"], sibling):
                        client.action("text", terminal, text=f"cd {shlex.quote(str(second_cwd))}\n")
                    deadline = time.monotonic() + 5
                    while True:
                        listing = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                        if listing["automatic_name"] == "second": break
                        self.assertLess(time.monotonic(), deadline, listing)
                        time.sleep(.05)
                    run("session", "rename", "-t", work_id, "renamed")
                    run("session", "has", "-t", "work", ok=False)
                    run("session", "has", "-t", "renamed")
                    run("session", "has", "-t", work_id)
                    os.kill(pane["pid"], 0)
                    renamed = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                    self.assertEqual(renamed["name"], "renamed")
                    run("session", "rename", "-t", work_id, "")
                    automatic = next(s for s in json.loads(run("session", "list", "--json")) if s["id"] == work_id)
                    self.assertIsNone(automatic["name"])
                    self.assertEqual(automatic["automatic_name"], "second")
                    run("session", "kill", "-t", work_id)
                    self.assertEqual(client.until(lambda m:m.get("type") == "session_closed")["workspace"], work_id)
                    run("session", "has", "-t", "work", ok=False)
                    self.assertEqual([s["id"] for s in json.loads(run("session", "list", "--json"))], [auto_id])
                    deadline = time.monotonic() + 5
                    while True:
                        try: os.kill(pane["pid"], 0)
                        except ProcessLookupError: break
                        self.assertLess(time.monotonic(), deadline, "Killed session's PTY survived")
                        time.sleep(.03)
                    os.kill(other_pane["pid"], 0)
                    self.assertEqual(run("session", "new", "-d", "-s", "work").strip(), "$3")
                    self.assertEqual(client.action("create", kind="tab")["type"], "error", "Old attachment must not control a reused name")
                    self.assertTrue(all(s["panes"] == 1 for s in json.loads(run("session", "list", "--json"))))
                    self.assertIsNone(owner.process.poll())
                finally:
                    client.socket.close(); other.socket.close()
            group = run("session", "--help").split("Commands:", 1)[1].split("Flags:", 1)[0]
            for name in ("list", "attach", "new", "kill", "has", "rename"):
                self.assertRegex(group, rf"(?m)^  {name}\s")
            # Session commands live in their group only: no top-level or tmux spellings.
            for gone in ("list-sessions", "new-session", "attach-session", "kill-session", "has-session", "ls", "new", "attach", "has"):
                run(gone, "--help", ok=False)

if __name__ == "__main__": unittest.main()
