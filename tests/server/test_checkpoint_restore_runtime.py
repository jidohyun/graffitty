"""Launch the actual Rust restore path into a headless engine and live PTYs."""

import contextlib
import functools
import http.server
import sys
import json
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
PROJECT = Path(os.environ.get("GRAFFITTY_TEST_PROJECT", ROOT / "frontends/godot/project"))
GODOT = (
    os.environ.get("GRAFFITTY_TEST_GODOT")
    or shutil.which("godot")
    or "/Applications/Godot.app/Contents/MacOS/Godot"
)


@unittest.skipUnless(Path(GODOT).is_file(), "Godot runtime not installed")
class RestoreRuntime(unittest.TestCase):
    def runtime(self, root):
        """The CLI's restore launches this headless engine as its frontend."""
        (root / "tools").mkdir()
        binary = root / "tools/gft"
        shutil.copy2(Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "dist/bin/gft")), binary)
        log = root / "runtime.log"
        launcher = root / "tools/frontend"
        launcher.write_text(
            "#!/bin/sh\ntest \"$1\" = -- || exit 2\nshift\necho $$ > "
            + shlex.quote(str(root / "frontend.pid"))
            + "\nexec "
            + shlex.quote(GODOT)
            + " --headless --path "
            + shlex.quote(str(PROJECT))
            + ' --script tests/checkpoint_restore_smoke.gd -- "$@" > '
            + shlex.quote(str(log))
            + " 2>&1\n"
        )
        launcher.chmod(0o700)
        return binary, log

    def stop_frontend(self, root):
        """The restored app outlives the CLI that launched it."""
        pid = root / "frontend.pid"
        if pid.exists():
            with contextlib.suppress(ProcessLookupError, ValueError):
                os.kill(int(pid.read_text()), signal.SIGTERM)

    def environment(self, root, binary):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_",))}
        env.pop("CODEX_THREAD_ID", None)
        if os.environ.get("GRAFFITTY_CHROMIUM_HOST"):
            env["GRAFFITTY_CHROMIUM_HOST"] = os.environ["GRAFFITTY_CHROMIUM_HOST"]
        env["PATH"] = str(root / "tools") + os.pathsep + env.get("PATH", "")
        env["GRAFFITTY_CHECKPOINT_DIR"] = str(root / "state")
        env["GRAFFITTY_BIN"] = str(binary)
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        return env

    def test_a_failed_restore_reports_its_reason_at_once(self):
        with tempfile.TemporaryDirectory(prefix="alm-restore-failure-") as tmp, contextlib.ExitStack() as owners:
            root = Path(tmp).resolve()
            binary, log = self.runtime(root)
            fixture = json.loads((ROOT / "tests/fixtures/checkpoint-layout.json").read_text())
            fixture["windows"] = fixture["windows"][:1]
            tree_root = root / "tree"
            tree_root.mkdir()
            fixture["windows"][0]["panes"][1]["filetree"] = {"owner": fixture["windows"][0]["panes"][0]["id"], "root": str(tree_root)}
            checkpoint = root / "checkpoint.json"
            checkpoint.write_text(json.dumps(fixture))
            env = self.environment(root, binary)
            # The filetree cannot start, so the import stops there.
            env["GRAFFITTY_SERVER__FILETREE__COMMAND"] = json.dumps([str(root / "missing-nvim")])
            owners.enter_context(PrivateServer(env, root, "/bin/sh"))
            owners.callback(self.stop_frontend, root)
            started = time.monotonic()
            result = subprocess.run([str(binary), "checkpoint", "restore", "--frontend", str(root / "tools/frontend"), "--checkpoint", str(checkpoint)],
                                    env=env, capture_output=True, text=True, timeout=65)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertLess(time.monotonic() - started, 30, "A failed import reports at once rather than timing out")
            self.assertIn("restore failed", result.stderr, log.read_text() if log.exists() else "")
            receipt = json.loads(result.stderr.split("restore failed: ", 1)[1])
            self.assertEqual(receipt["ok"], False)
            self.assertTrue(receipt["error"])

    def test_cli_restores_all_windows_tabs_and_panes_and_reports_ready(self):
        with tempfile.TemporaryDirectory(prefix="alm-restore-runtime-") as tmp, contextlib.ExitStack() as owners:
            root = Path(tmp).resolve()
            binary, log = self.runtime(root)
            # Prove the exact root ID, cwd and provider account reach the process.
            provider = root / "account"
            provider.mkdir()
            agent_log = root / "resumed.txt"
            agent = root / "codex"
            agent.write_text(
                '#!/bin/sh\nprintf \'%s\\n\' "$@" "$PWD" "$CODEX_HOME" > '
                + shlex.quote(str(agent_log))
                + "\nsleep 5\n"
            )
            agent.chmod(0o700)
            fixture = json.loads(
                (ROOT / "tests/fixtures/checkpoint-layout.json").read_text()
            )
            # Freeze pane physics so the assertion compares restored positions,
            # not the result of the first second of intentional simulation.
            for window in fixture["windows"]:
                for tab in window["tabs"]:
                    tab["tree"]["physics"] = False
                    tab["tree"]["tiling_gap"] = 8.0
                    tab["graph_visual"] = {"reroutes": {}, "routes": {}, "serial": 0}
            fixture["windows"][0]["panes"][0]["agent"] = {
                "kind": "codex",
                "session_id": "22222222-2222-4222-8222-222222222222",
                "executable": str(agent),
                "env": {"CODEX_HOME": str(provider)},
            }
            # Recreate a connected filetree from just owner/root metadata. The
            # stand-in records its launch and keeps a real PTY alive without
            # downloading Neovim plugins during this test.
            tree_root = root / "tree root"
            tree_root.mkdir()
            tree_log = root / "filetree.txt"
            nvim = root / "nvim"
            nvim.write_text("#!/bin/sh\ncd -- \"$GRAFFITTY_FILETREE_ROOT\"\nprintf '%s\\n' \"$GRAFFITTY_FILETREE_OWNER\" \"$PWD\" > "
                            + shlex.quote(str(tree_log)) + '\nexec /bin/cat\n')
            nvim.chmod(0o700)
            fixture["windows"][0]["panes"][1]["filetree"] = {"owner": fixture["windows"][0]["panes"][0]["id"], "root": str(tree_root)}
            ports = {"inputs": [{"id": "in"}], "outputs": [{"id": "out", "mode": "send"}]}
            fixture["windows"][1]["graph"] = {
                "nodes": [{"node": f"%{i}", "manifest": ports} for i in (10, 11)],
                "edges": [{"from": "%10", "to": "%11", "from_port": "out", "to_port": "in",
                           "muted": True, "contains": "keep", "outcome": "success", "stop_at": 4102444800}],
                "run_messages": 42,
            }
            fixture["windows"][1]["tabs"][0]["graph_visual"] = {
                "reroutes": {"r1": {"position": {"vec2": [650, 120]}}},
                "routes": {"%10/out>%11/in": ["r1"]},
            }
            # Chromiums reopen from their pages and profile: one beside its
            # owner, one alone in a tab of the other window, without an owner,
            # from a profile template.
            pages = root / "pages"
            pages.mkdir()
            for name in ("first", "second", "third"):
                (pages / f"{name}.html").write_text(f"<title>{name}</title>{name}")
            handler = type("Quiet", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *_: None})
            web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(handler, directory=str(pages)))
            threading.Thread(target=web.serve_forever, daemon=True).start()
            owners.callback(web.server_close)
            owners.callback(web.shutdown)
            base = f"http://127.0.0.1:{web.server_address[1]}"
            template = root / "profile template"
            (template / "Default").mkdir(parents=True)
            fixture["windows"][0]["chromiums"] = [{"id": 20, "owner": fixture["windows"][0]["panes"][0]["id"], "title": "Docs", "profile": "",
                                                  "urls": [base + "/second.html", base + "/first.html"]}]
            fixture["windows"][0]["tabs"][0]["tree"]["windows"].append(
                {"pane": "%20", "shown": True, "rect": {"rect2": [920, 80, 420, 500]}})
            fixture["windows"][1]["chromiums"] = [{"id": 21, "owner": None, "title": "", "profile_template": str(template),
                                                  "urls": [base + "/third.html"]}]
            fixture["windows"][1]["tabs"].append({"id": 21, "focused": "%21",
                "tree": {"windows": [{"pane": "%21", "shown": True, "rect": {"rect2": [20, 80, 600, 400]}}],
                         "physics": False, "tiling_gap": 8.0},
                "graph_visual": {"reroutes": {}, "routes": {}, "serial": 0}})
            # An opted-in node relaunches with its command, directory,
            # environment and reported state.
            node_log = root / "node.txt"
            node = root / "fake-node"
            node.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" \"$PWD\" \"$MODE\" > " + shlex.quote(str(node_log))
                            + "\ncat \"$GRAFFITTY_NODE_STATE\" >> " + shlex.quote(str(node_log)) + "\nsleep 5\n")
            node.chmod(0o700)
            node_dir = root / "node dir"
            node_dir.mkdir()
            fixture["windows"][0]["panes"][2]["node"] = {"command": [str(node), "--strict"], "cwd": str(node_dir),
                                                         "env": {"MODE": "judge"}, "state": {"cursor": 3}}
            # Only checkpoints in the private history relaunch node commands.
            history = root / "state" / "manual".encode().hex()
            history.mkdir(parents=True, mode=0o700)
            checkpoint = history / "checkpoint-00000000000000000001-runtime.json"
            checkpoint.write_text(json.dumps(fixture))
            env = self.environment(root, binary)
            env["GRAFFITTY_SERVER__FILETREE__COMMAND"] = json.dumps([str(nvim)])
            owners.enter_context(PrivateServer(env, root, "/bin/sh"))
            owners.callback(self.stop_frontend, root)
            result = subprocess.run(
                [str(binary), "checkpoint", "restore", "--frontend", str(root / "tools/frontend"), "--checkpoint", str(checkpoint)],
                env=env,
                capture_output=True,
                text=True,
                timeout=65,
            )
            self.assertEqual(
                result.returncode,
                0,
                result.stderr + (log.read_text() if log.exists() else ""),
            )
            self.assertGreater(json.loads(result.stdout)["pid"], 0)
            # Nothing live had these IDs, so every pane, chromium and filetree kept its own.
            self.assertEqual(json.loads(result.stdout)["renumbered"], {}, result.stdout)
            deadline = time.monotonic() + 10
            while (
                time.monotonic() < deadline
                and "CHECKPOINT RESTORE SMOKE:" not in log.read_text()
            ):
                time.sleep(0.1)
            output = log.read_text()
            self.assertIn("CHECKPOINT RESTORE SMOKE: PASS", output)
            self.assertNotIn("SCRIPT ERROR", output)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and len(node_log.read_text().splitlines() if node_log.exists() else []) < 4:
                time.sleep(0.1)
            self.assertEqual(node_log.read_text().splitlines(), ["--strict", str(node_dir), "judge", '{"cursor":3}'])

            self.assertEqual(tree_log.read_text().splitlines()[1], str(tree_root))
            self.assertTrue(tree_log.read_text().splitlines()[0].startswith("%"))
            self.assertEqual(
                agent_log.read_text().splitlines(),
                [
                    "resume",
                    "22222222-2222-4222-8222-222222222222",
                    # A symlinked directory keeps the path as saved in PWD.
                    "/tmp",
                    str(provider),
                ],
            )
