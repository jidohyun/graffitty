"""Exact-thread CLI routing through a private owner, without a Godot frontend."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient, local_socket

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))


@unittest.skipUnless(os.name == "posix", "POSIX process-owned rollout fixture")
class AgentContextTests(unittest.TestCase):
    def test_detached_owner_routes_exact_threads_and_rejects_stale_context(self):
        with tempfile.TemporaryDirectory(prefix="gft-context-") as directory:
            root = Path(directory).resolve()
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            executable = root / "codex"
            shutil.copy("/bin/cat", executable)
            sessions = root / "provider" / "sessions"
            sessions.mkdir(parents=True)
            threads = [str(uuid.uuid4()), str(uuid.uuid4())]
            rollouts = []
            for thread in threads:
                path = sessions / f"rollout-test-{thread}.jsonl"
                path.write_text(json.dumps({"type": "session_meta", "payload": {"id": thread, "source": "cli"}}) + "\n")
                rollouts.append(path)

            def cli(*args, extra=None):
                return subprocess.run([CLI, *args], env={**env, **(extra or {})},
                                      capture_output=True, text=True, timeout=35)

            with PrivateServer(env, root, "/bin/sh") as owner:
                created = cli("session", "new", "-d", "-s", "routing", "-c", str(root))
                self.assertEqual(created.returncode, 0, created.stderr)
                local = json.loads(owner.descriptor.read_text())["local"]

                def context_request(token, params, version=1):
                    sock = local_socket(local["url"], timeout=35)
                    try:
                        sock.sendall((json.dumps({"version": version, "id": "test", "token": token,
                                                  "method": "agent.context", "params": params}) + "\n").encode())
                        data = bytearray()
                        while not data.endswith(b"\n"):
                            chunk = sock.recv(65536)
                            if not chunk:
                                raise EOFError("owner closed before replying to agent.context")
                            data.extend(chunk)
                        return json.loads(data)
                    finally:
                        sock.close()

                client = PrivateClient(local, "routing")
                try:
                    first = client.topology["panes"][0]["id"]
                    second = client.action("create", first, kind="pane")["created"]

                    def launch(pane, rollout):
                        # A real foreground PID holds its own rollout open. No
                        # hooks, graph registration, provider daemon or model calls.
                        command = f"exec 3<{shlex.quote(str(rollout))}; exec {shlex.quote(str(executable))}"
                        for method, params in (("terminal.type", {"text": command, "interval_ms": 0}),
                                               ("terminal.press", {"key": "Enter"})):
                            reply = client.action("rpc", pane, method=method, params=params)
                            self.assertNotIn("error", reply, reply)

                    launch(first, rollouts[0])
                    launch(second, rollouts[1])
                    deadline = time.monotonic() + 10
                    while True:
                        result = cli("graph", "adjacent", extra={"CODEX_THREAD_ID": threads[1]})
                        if result.returncode == 0:
                            break
                        self.assertLess(time.monotonic(), deadline, result.stdout)
                        time.sleep(.1)
                    self.assertEqual(json.loads(result.stdout)["result"]["self"], f"%{second}")

                    first_context = context_request(local["token"], {"thread_id": threads[0]})["result"]
                    stale = {"GRAFFITTY_SOCKET": local["url"], "GRAFFITTY_TOKEN": first_context["token"]}
                    result = cli("graph", "adjacent", extra={**stale, "CODEX_THREAD_ID": threads[1]})
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(json.loads(result.stdout)["result"]["self"], f"%{second}")
                    result = cli("graph", "adjacent", extra={**stale, "CODEX_THREAD_ID": str(uuid.uuid4())})
                    self.assertEqual(json.loads(result.stdout)["error"]["code"], "missing_context")

                    for token, params, version, code in [
                        (first_context["token"], {"thread_id": threads[1]}, 1, "unauthorized"),
                        (local["token"], {"thread_id": "invalid"}, 1, "invalid_thread"),
                        (local["token"], [], 1, "invalid_params"),
                        (local["token"], {"thread_id": threads[1]}, 2, "unsupported_version"),
                    ]:
                        self.assertEqual(context_request(token, params, version)["error"]["code"], code)

                    duplicate = client.action("create", first, kind="pane")["created"]
                    launch(duplicate, rollouts[1])
                    deadline = time.monotonic() + 10
                    while True:
                        result = cli("graph", "adjacent", extra={"CODEX_THREAD_ID": threads[1]})
                        if result.returncode != 0:
                            break
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.1)
                    self.assertIn("Found 2 live Graffitty panes", result.stdout)
                    client.action("close", pane=duplicate)
                    client.action("close", pane=second)
                    result = cli("graph", "adjacent", extra={**stale, "CODEX_THREAD_ID": threads[1]})
                    self.assertEqual(json.loads(result.stdout)["error"]["code"], "missing_context")
                finally:
                    client.socket.close()


if __name__ == "__main__":
    unittest.main()
