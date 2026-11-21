"""Snapshots are produced by a detached server, including wiring and filetrees."""
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))


class ServerCheckpoints(unittest.TestCase):
    def environment(self, root):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        env["GRAFFITTY_CHECKPOINT_DIR"] = str(root / "checkpoints")
        env["GRAFFITTY_SERVER__CHECKPOINTS__INTERVAL_SECONDS"] = "1"
        env["GRAFFITTY_SERVER__CHECKPOINTS__HISTORY"] = "2"
        return env

    def cli(self, env, *args):
        result = subprocess.run([CLI, *args], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_detached_auto_capture_and_manual_profile_preserve_layout_graph_and_filetree(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            # Exercise the real server filetree launch without downloading plugins.
            nvim = root / "nvim"
            # Visible root is reported by title; Neovim's cwd need not follow it.
            nvim.write_text("#!/bin/sh\nprintf '\\033]2;%s\\007' \"$GRAFFITTY_FILETREE_ROOT\"\nexec /bin/cat\n")
            nvim.chmod(0o700)
            tree_root = root / "visible tree root"
            tree_root.mkdir()
            env["GRAFFITTY_SERVER__FILETREE__COMMAND"] = json.dumps([str(nvim)])
            with PrivateServer(env, root, "/bin/sh") as owner:
                self.cli(env, "session", "new", "-d", "-s", "recovery", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "recovery")
                try:
                    first = client.topology["panes"][0]["id"]
                    second = client.action("create", first, kind="pane")["created"]

                    def rpc(pane, method, params):
                        reply = client.action("rpc", pane, method=method, params=params)
                        self.assertNotIn("error", reply, reply)
                        return reply["result"]

                    ports = {"inputs": [{"id": "in"}], "outputs": [{"id": "out", "mode": "send"}]}
                    for pane in (first, second):
                        rpc(pane, "agent.event", {"provider": "adapter", "event": "SessionStart"})
                        rpc(pane, "agent.register", ports)
                    edge = {"from": f"%{first}", "to": f"%{second}", "from_port": "out", "to_port": "in",
                            "muted": True, "contains": "keep", "outcome": "success", "stop_at": 4102444800}
                    rpc(first, "graph.connect", edge)
                    tree = rpc(first, "filetree.toggle", {"root": str(tree_root)})
                    tree_id = int(tree["pane"][1:])
                    state = client.action("workspace_get")["workspace_state"]
                    layout = state["layout"]["tabs"][str(first)]
                    layout.update(enabled=False, physics=False)
                    for window in layout["windows"]:
                        if window["key"] == f"%{second}":
                            window["rect"] = [650, 110, 420, 350]
                    result = client.action("workspace_edit", expected_revision=state["revision"],
                                           edit={"op": "tab", "tab": first, "layout": layout})
                    self.assertEqual(result["type"], "ack", result)
                    # The next automatic save must succeed with no attached client.
                finally:
                    client.socket.close()
                deadline = time.monotonic() + 15
                while True:
                    entries = json.loads(self.cli(env, "checkpoint", "list", "--tag", "auto"))
                    if entries:
                        saved = json.loads(Path(entries[0]["path"]).read_text())
                        # A save taken as the filetree opened precedes the root its
                        # program reports; a later one replaces it.
                        if any(p["id"] == tree_id and p.get("filetree", {}).get("root") == str(tree_root)
                               for p in saved["windows"][0]["panes"]):
                            break
                    self.assertLess(time.monotonic(), deadline, (owner.directory / "server.log").read_text())
                    time.sleep(.1)
                window = saved["windows"][0]
                self.assertEqual(saved["tag"], "auto")
                self.assertEqual(next(p for p in window["panes"] if p["id"] == tree_id)["filetree"],
                                 {"owner": first, "root": str(tree_root)})
                self.assertEqual(window["graph"]["edges"][0]["to"], f"%{second}")
                self.assertTrue(window["graph"]["edges"][0]["muted"])
                self.assertEqual(next(p for p in window["tabs"][0]["tree"]["windows"] if p["pane"] == f"%{second}")["rect"]["rect2"],
                                 [650, 110, 420, 350])
                manual = json.loads(self.cli(env, "checkpoint", "save"))
                self.assertEqual(json.loads(Path(manual["path"]).read_text())["tag"], "manual")
                self.assertEqual(len(json.loads(self.cli(env, "checkpoint", "list"))), 1)
                time.sleep(3)
                self.assertEqual(len(json.loads(self.cli(env, "checkpoint", "list", "--tag", "auto"))), 2)
                self.assertTrue(Path(manual["path"]).exists())

    @unittest.skipUnless(sys.platform == "darwin", "the Chromium host is built for macOS")
    def test_chromium_is_saved_as_its_pages_and_profile(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-chromium-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            pages = root / "pages"
            pages.mkdir()
            for name in ("first", "second"):
                (pages / f"{name}.html").write_text(f"<title>{name}</title>{name}")
            handler = type("Quiet", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *_: None})
            web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(handler, directory=str(pages)))
            threading.Thread(target=web.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{web.server_address[1]}"
            try:
                with PrivateServer(env, root, "/bin/sh") as owner:
                    self.cli(env, "session", "new", "-d", "-s", "browsing", "-c", str(root))
                    client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "browsing")
                    try:
                        first = client.topology["panes"][0]["id"]

                        def rpc(method, params):
                            reply = client.action("rpc", first, method=method, params=params)
                            self.assertNotIn("error", reply, reply)
                            return reply["result"]

                        chromium = rpc("chromium.create", {"url": base + "/first.html"})["chromium"]
                        rpc("chromium.command", {"chromium": chromium, "action": "tab-new",
                                                 "args": {"url": base + "/second.html"}})
                        rpc("chromium.set_title", {"chromium": chromium, "title": "Docs"})
                    finally:
                        client.socket.close()
                    deadline = time.monotonic() + 45
                    while True:
                        entries = json.loads(self.cli(env, "checkpoint", "list", "--tag", "auto"))
                        saved = json.loads(Path(entries[0]["path"]).read_text()) if entries else {"windows": [{"chromiums": []}]}
                        window = saved["windows"][0]
                        if window["chromiums"] and len(window["chromiums"][0]["urls"]) == 2:
                            break
                        self.assertLess(time.monotonic(), deadline, (owner.directory / "server.log").read_text())
                        time.sleep(.2)
                    # The selected page, the new tab, comes first; no page state is kept.
                    self.assertEqual(window["chromiums"], [{"id": int(chromium[1:]), "owner": first, "title": "Docs",
                        "urls": [base + "/second.html", base + "/first.html"], "profile": ""}])
                    self.assertIn(chromium, [w["pane"] for tab in window["tabs"] for w in tab["tree"]["windows"]])
                    # A restore receives the chromium list unchanged.
                    prepared = json.loads(self.cli(env, "checkpoint", "restore", "--tag", "auto", "--prepare-only", "--checkpoint", "0"))
                    self.assertEqual(json.loads(Path(prepared["prepared"]).read_text())["windows"][0]["chromiums"], window["chromiums"])
            finally:
                web.shutdown()
                web.server_close()

    @unittest.skipUnless(importlib.util.find_spec("pydantic"), "the Python node SDK needs pydantic")
    def test_opted_in_nodes_are_saved_with_their_relaunch_and_state(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-nodes-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            # A real SDK node: its own pydantic Restore describes the relaunch.
            node = root / "judge.py"
            node.write_text(textwrap.dedent("""
                import asyncio
                from graffitty_graph_protocol import Restore, Session
                async def main():
                    async with Session(restore=Restore.current_process()) as session:
                        await session.report_state({"cursor": 3})
                        while True:
                            await session.heartbeat()
                            await asyncio.sleep(1)
                asyncio.run(main())
            """))
            sdk = ROOT / "python/libs/graffitty-graph-protocol/src"
            with PrivateServer(env, root, "/bin/sh") as owner:
                self.cli(env, "session", "new", "-d", "-s", "nodes", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "nodes")
                try:
                    custom = client.topology["panes"][0]["id"]
                    builtin = client.action("create", custom, kind="pane")["created"]
                    for pane, command in ((custom, f"PYTHONPATH={shlex.quote(str(sdk))} {shlex.quote(sys.executable)} {shlex.quote(str(node))}"),
                                          (builtin, f"{shlex.quote(str(CLI))} node payload-inspector")):
                        for method, params in (("terminal.type", {"text": command, "interval_ms": 0}), ("terminal.press", {"key": "Enter"})):
                            reply = client.action("rpc", pane, method=method, params=params)
                            self.assertNotIn("error", reply, reply)
                finally:
                    client.socket.close()
                deadline = time.monotonic() + 30
                while True:
                    saved = json.loads(Path(json.loads(self.cli(env, "checkpoint", "save"))["path"]).read_text())
                    panes = {p["id"]: p for p in saved["windows"][0]["panes"]}
                    if all("node" in panes[pane] for pane in (custom, builtin)) and "state" in panes[custom]["node"]:
                        break
                    self.assertLess(time.monotonic(), deadline, (owner.directory / "server.log").read_text())
                    time.sleep(.3)
                declared = panes[custom]["node"]
                self.assertEqual((declared["command"], declared["cwd"], declared["state"]), ([sys.executable, str(node)], str(root), {"cursor": 3}))
                self.assertGreater(declared["pid"], 0)
                # Built-in nodes opt in by themselves, as gft with their own arguments.
                self.assertEqual((panes[builtin]["node"]["command"], panes[builtin]["node"]["cwd"]), (["gft", "node", "payload-inspector"], str(root)))
                prepared = json.loads(self.cli(env, "checkpoint", "restore", "--prepare-only", "--checkpoint", "0"))
                restored = {p["id"]: p for p in json.loads(Path(prepared["prepared"]).read_text())["windows"][0]["panes"]}
                for pane, program in ((custom, sys.executable), (builtin, str(CLI.resolve()))):
                    script = Path(restored[pane]["restore_shell"]).read_text()
                    command = next(shlex.split(line)[1:] for line in script.splitlines() if line.startswith("exec ") and not line.endswith(" -l"))
                    self.assertEqual(str(Path(command[0]).resolve()), str(Path(program).resolve()), script)

    def test_auto_can_be_disabled_while_manual_saves_still_work(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-off-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            env["GRAFFITTY_SERVER__CHECKPOINTS__ENABLED"] = "false"
            with PrivateServer(env, root, "/bin/sh") as owner:
                self.cli(env, "session", "new", "-d", "-s", "manual-only", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "manual-only")
                try:
                    pane = client.topology["panes"][0]["id"]
                    for event in ("SessionStart", "SessionEnd"):
                        client.action("rpc", pane, method="agent.event", params={"provider": "adapter", "event": event})
                finally:
                    client.socket.close()
                self.cli(env, "checkpoint", "save")
                time.sleep(1.5)
                self.assertEqual(json.loads(self.cli(env, "checkpoint", "list", "--tag", "auto")), [])
                self.assertEqual(len(json.loads(self.cli(env, "checkpoint", "list"))), 1)

    def wait_auto(self, root, count, owner):
        deadline = time.monotonic() + 20
        while True:
            paths = sorted((root / "checkpoints" / "6175746f").glob("checkpoint-*.json"))
            if len(paths) >= count:
                return paths
            self.assertLess(time.monotonic(), deadline, (owner.directory / "server.log").read_text())
            time.sleep(.05)

    def test_native_start_and_real_exit_save_without_waiting_for_default_timer(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-native-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            env.pop("GRAFFITTY_SERVER__CHECKPOINTS__INTERVAL_SECONDS")
            env["GRAFFITTY_SERVER__CHECKPOINTS__HISTORY"] = "20"
            # A foreground executable with an exact, open conversation file,
            # exercising real process discovery without contacting a provider.
            agent = root / "codex"
            shutil.copyfile("/bin/cat", agent)
            agent.chmod(0o700)
            session_id = "11111111-1111-4111-8111-111111111111"
            rollout = root / "account" / "sessions" / f"rollout-today-{session_id}.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(json.dumps({"type": "session_meta", "payload": {
                "id": session_id, "session_id": session_id}}) + "\n")
            with PrivateServer(env, root, "/bin/sh") as owner:
                self.cli(env, "session", "new", "-d", "-s", "native", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "native")
                try:
                    pane = client.topology["panes"][0]["id"]
                    command = f"{shlex.quote(str(agent))} 3< {shlex.quote(str(rollout))}\n"
                    client.action("text", pane, text=command)
                    paths = self.wait_auto(root, 1, owner)
                    saved = json.loads(paths[-1].read_text())
                    resumed = saved["windows"][0]["panes"][0]["agent"]
                    self.assertEqual(resumed["session_id"], session_id)
                    # An end hook runs before process exit. Neither that hook,
                    # repeated starts (compaction), nor Stop may save again.
                    for event in ("SessionStart", "Stop", "SessionEnd"):
                        result = client.action("rpc", pane, method="agent.event", params={
                            "provider": "codex", "event": event, "pid": resumed["pid"],
                            "session_id": session_id, "integrated": True})
                        self.assertNotIn("error", result, result)
                    time.sleep(4)
                    self.assertEqual(len(self.wait_auto(root, 1, owner)), 1)
                    client.action("text", pane, text="\x03")
                    paths = self.wait_auto(root, 2, owner)
                    ended = json.loads(paths[-1].read_text())
                    self.assertNotIn("agent", ended["windows"][0]["panes"][0])
                    self.assertEqual(len(paths), 2)
                finally:
                    client.socket.close()

    def test_lifecycle_save_restarts_timer_and_keeps_one_auto_history(self):
        with tempfile.TemporaryDirectory(prefix="gr-checkpoint-reset-") as tmp:
            root = Path(tmp).resolve()
            env = self.environment(root)
            env["GRAFFITTY_SERVER__CHECKPOINTS__INTERVAL_SECONDS"] = "6"
            env["GRAFFITTY_SERVER__CHECKPOINTS__HISTORY"] = "20"
            with PrivateServer(env, root, "/bin/sh") as owner:
                self.cli(env, "session", "new", "-d", "-s", "reset", "-c", str(root))
                client = PrivateClient(json.loads(owner.descriptor.read_text())["local"], "reset")
                try:
                    pane = client.topology["panes"][0]["id"]
                    time.sleep(2)
                    # A save that would repeat the newest entry is skipped, so the
                    # shell moves to another directory before each save this
                    # test expects: every snapshot then differs from the last.
                    def move(directory):
                        client.action("text", pane, text=f"cd {shlex.quote(str(directory))}\n")
                        time.sleep(.5)

                    def event(name):
                        reply = client.action("rpc", pane, method="agent.event", params={
                            "provider": "adapter", "event": name, "session_id": "adapter-test"})
                        self.assertNotIn("error", reply, reply)

                    def newest_directory():
                        paths = self.wait_auto(root, 1, owner)
                        return json.loads(paths[-1].read_text())["windows"][0]["panes"][0]["cwd"]

                    started = time.monotonic()  # About two seconds after the server's timer began.
                    event("SessionStart")
                    self.wait_auto(root, 1, owner)
                    move(root / "checkpoints")
                    # Past the timer's original six-second deadline. The start
                    # snapshot restarted the timer, so nothing was saved yet,
                    # although the state has changed.
                    time.sleep(max(0, started + 4.6 - time.monotonic()))
                    self.assertEqual(len(self.wait_auto(root, 1, owner)), 1)
                    # Six seconds after that snapshot the timer saves the change.
                    self.wait_auto(root, 2, owner)
                    self.assertGreaterEqual(time.monotonic() - started, 5.5)
                    self.assertEqual(newest_directory(), str(root / "checkpoints"))
                    # A session's end is saved at once, not at the next timer.
                    move(root / "session-owner")
                    event("SessionEnd")
                    deadline = time.monotonic() + 4
                    while newest_directory() != str(root / "session-owner"):
                        self.assertLess(time.monotonic(), deadline, "the session's end was not saved promptly")
                        time.sleep(.05)
                    # Entries closer together than the interval replace each other.
                    self.assertLessEqual(len(self.wait_auto(root, 2, owner)), 3)
                    self.assertEqual(json.loads(self.cli(env, "checkpoint", "list")), [])
                finally:
                    client.socket.close()


if __name__ == "__main__":
    unittest.main()
