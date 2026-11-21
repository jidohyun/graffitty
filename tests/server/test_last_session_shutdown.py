"""Observe natural owner exit before PrivateServer's failure cleanup runs."""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support", "tools")]
import dev_server
from e2e_server import PrivateServer
from test_session_transfer import Peer
from private_session_e2e import local_socket


class LastSessionShutdownTests(unittest.TestCase):
    @contextlib.contextmanager
    def owner(self):
        evidence = os.environ.get("GRAFFITTY_TEST_EVIDENCE")
        if evidence:
            Path(evidence).mkdir(parents=True, exist_ok=True)
        temporary = (contextlib.nullcontext(tempfile.mkdtemp(prefix="gr-last-session-", dir=evidence))
                     if evidence else tempfile.TemporaryDirectory(prefix="gr-last-session-"))
        with temporary as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            if os.name == "nt":
                # Exercise ordinary startup without an ambient test workaround.
                # The default PowerShell launch must survive pane resizing even
                # when update notifications are enabled.
                env.pop("POWERSHELL_UPDATECHECK", None)
            shell = os.environ.get("GRAFFITTY_TEST_SHELL", "pwsh.exe" if os.name == "nt" else "/bin/sh")
            with PrivateServer(env, directory, shell) as owner:
                owner.local = json.loads(owner.descriptor.read_text())["local"]
                owner.shell_handles = {}
                try:
                    yield owner
                finally:
                    if os.name == "nt":
                        for handle in owner.shell_handles.values():
                            self.kernel.CloseHandle(handle)

    def watch_panes(self, owner, panes):
        if os.name != "nt":
            return
        import ctypes
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        self.kernel.OpenProcess.restype = ctypes.c_void_p
        self.kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        for pane in panes:
            pid = pane["pid"]
            if pid not in owner.shell_handles:
                handle = self.kernel.OpenProcess(0x100000, False, pid)
                if not handle:
                    raise ctypes.WinError(ctypes.get_last_error())
                owner.shell_handles[pid] = handle

    def cli(self, owner, *args):
        result = subprocess.run([owner.binary, *args],
                                env=owner.env, capture_output=True, text=True, encoding="utf-8", timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def assert_gone(self, pid, owner):
        if os.name == "nt":
            # Retain the exact process before closing it. Opening a PID after
            # shutdown can inspect an unrelated process that reused the number.
            self.assertEqual(self.kernel.WaitForSingleObject(owner.shell_handles[pid], 0), 0,
                             f"Original shell {pid} is still live")
            return
        # A zombie still answers kill(0); it cannot pass this check.
        with self.assertRaises(ProcessLookupError, msg=f"Shell {pid} was not reaped"):
            os.kill(pid, 0)

    def assert_stopped(self, owner, panes):
        self.assertEqual(owner.process.wait(timeout=5), 0)
        for pane in panes:
            self.assert_gone(pane["pid"], owner)
        self.assertFalse(owner.descriptor.exists())
        with self.assertRaises(OSError):
            probe = local_socket(owner.local["url"])
            probe.close()
        self.assertIsNone(dev_server.running_server(owner.binary, owner.descriptor, owner.env))
        with patch("builtins.input", side_effect=AssertionError("No restart prompt after shutdown")):
            self.assertIsNone(dev_server.restart_if_requested(owner.binary, owner.descriptor, owner.env))

    def test_last_pane_tab_cli_exit_and_eof_with_attached_observer(self):
        # Ctrl+D is a Unix line-discipline EOF, not a Windows console EOF.
        routes = ("pane", "tab", "kill", "exit") + (() if os.name == "nt" else ("eof",))
        for route in routes:
            with self.subTest(route=route), self.owner() as owner:
                with contextlib.ExitStack() as stack:
                    peer = Peer(owner.local, "closing")
                    stack.callback(peer.socket.close)
                    pane = peer.topology["panes"][0]
                    if route in ("tab", "kill"):
                        self.assertEqual(peer.action("create", pane["id"], kind="pane")["type"], "ack")
                    panes = peer.sync()["panes"]
                    self.watch_panes(owner, panes)
                    observer = Peer(owner.local, "closing")
                    stack.callback(observer.socket.close)
                    if route == "pane":
                        result = peer.action("close", pane["id"])
                    elif route == "tab":
                        result = peer.action("close_group", tab=pane["tab"])
                    elif route == "kill":
                        self.cli(owner, "session", "kill", "-t", "closing")
                        result = {"type": "ack"}
                    else:
                        result = peer.action("text", pane["id"], text=("exit\r" if os.name == "nt" else "exit\n") if route == "exit" else "\x04")
                    self.assertEqual(result["type"], "ack", "Final close must receive its success reply")
                    # Sessions are addressed by the id the server reported at
                    # attach; "closing" is only this session's display name.
                    self.assertRegex(observer.workspace, r"^\$\d+$")
                    self.assertEqual(observer.until(lambda m: m.get("type") == "session_closed")["workspace"], observer.workspace)
                    self.assert_stopped(owner, panes)

    def test_other_detached_session_survives_and_retains_its_shell(self):
        with self.owner() as owner, contextlib.ExitStack() as stack:
            first, second = Peer(owner.local, "A"), Peer(owner.local, "B")
            stack.callback(first.socket.close)
            stack.callback(second.socket.close)
            pane = first.topology["panes"][0]
            sibling = second.topology["panes"][0]
            self.watch_panes(owner, [pane, sibling])
            split = first.action("create", pane["id"], kind="pane")["created"]
            tab = first.action("create", kind="tab")["created"]
            command = "Write-Output ('retained-' + 'marker')\r" if os.name == "nt" else "printf 'retained-%s\\n' marker\n"
            second.action("text", sibling["id"], text=command)
            deadline = time.monotonic() + 10
            while True:
                second.send({"type": "history", "session": sibling["id"]})
                text = second.until(lambda m: m.get("type") == "history")["text"]
                if os.environ.get("GRAFFITTY_TEST_EVIDENCE"):
                    (owner.directory / "sibling-history.txt").write_text(text, encoding="utf-8")
                if "retained-marker" in text:
                    break
                self.assertLess(time.monotonic(), deadline, "Shell did not finish its marker command")
                time.sleep(.02)
            second.socket.close()
            first.action("close", split)
            first.action("close_group", tab=pane["tab"])
            self.assertEqual([p["id"] for p in first.sync()["panes"]], [tab])
            first.action("close", tab)
            first.until(lambda m: m.get("type") == "session_closed")
            self.assertEqual([s["name"] for s in json.loads(self.cli(owner, "session", "list", "--json"))], ["B"])
            # A detached live pane keeps the daemon alive without observers.
            time.sleep(.2)
            self.assertIsNone(owner.process.poll())
            again = Peer(owner.local, "B")
            stack.callback(again.socket.close)
            self.assertEqual(again.topology["panes"][0]["pid"], sibling["pid"])
            self.assertEqual(again.topology["panes"][0]["id"], sibling["id"])
            again.send({"type": "history", "session": sibling["id"]})
            self.assertIn("retained-marker", again.until(lambda m: m.get("type") == "history")["text"])
            again.socket.close()
            self.cli(owner, "session", "kill", "-t", "B")
            self.assert_stopped(owner, [sibling])

    def test_shell_exit_while_detached_and_empty_startup_waits_for_first_session(self):
        with self.owner() as owner:
            time.sleep(.2)
            self.assertIsNone(owner.process.poll(), "Bootstrap needs time to create its first session")
            self.assertEqual(json.loads(self.cli(owner, "session", "list", "--json")), [])
            peer = Peer(owner.local, "delayed")
            try:
                panes = peer.topology["panes"]
                self.watch_panes(owner, panes)
                command = "Start-Sleep -Milliseconds 200; exit\r" if os.name == "nt" else "sleep .2; exit\n"
                self.assertEqual(peer.action("text", panes[0]["id"], text=command)["type"], "ack")
            finally:
                peer.socket.close()
            self.assert_stopped(owner, panes)


if __name__ == "__main__":
    unittest.main()
