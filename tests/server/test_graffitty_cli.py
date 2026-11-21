"""Native CLI integration tests; no GUI, live workspace, or desktop input needed."""

import json
import fcntl
import pty
import termios
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "dist/bin/gft"


def copy_shell(destination):
    """Copies a shell that keeps running as that copy, so the copy's name is the
    process's program. macOS's /bin/sh only re-executes /bin/bash, and the
    system then reports /bin/bash, not the copy."""
    shutil.copy("/bin/bash" if sys.platform == "darwin" else os.path.realpath("/bin/sh"), destination)


def run(*args, env=None, input=None, binary=BIN, foreground=None):
    isolated = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("GRAFFITTY_", "TERMCTL_", "CODEX_THREAD_ID"))
    }
    isolated["PATH"] = str(binary.parent) + os.pathsep + isolated.get("PATH", "")
    isolated.update(env or {})
    def invoke(command, **kwargs):
        return subprocess.run(command, env=isolated, input=input,
                              capture_output=True, text=True, check=False,
                              timeout=10, **kwargs)
    if foreground is None:
        return invoke([str(binary), *args])
    # Hooks inherit a real foreground provider ancestor, not an environment PID.
    with tempfile.TemporaryDirectory(prefix="hook-owner-") as directory:
        launcher = Path(directory) / foreground
        copy_shell(launcher)
        master, slave = pty.openpty()
        try:
            return invoke([str(launcher), "-c", '"$@"; exit $?' , "hook", str(binary), *args],
                          start_new_session=True, pass_fds=(slave,),
                          preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
        finally:
            os.close(master)
            os.close(slave)


class CliTests(unittest.TestCase):
    def test_internal_commands_are_grouped_last(self):
        result = run("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        before, internal = result.stdout.split("Internal:\n", 1)
        # One word per thing; the actions are inside each group.
        for group in ("session", "tab", "pane", "terminal", "graph", "chromium"):
            self.assertRegex(before, rf"(?m)^  {group}\s")
        for moved in ("get-text", "pid", "panes", "list-panes", "select-pane", "list-sessions", "new-session",
                      "rename-tab", "place", "run", "layout", "send", "put", "icat", "completion"):
            self.assertNotRegex(before, rf"(?m)^  {moved}\s")
        self.assertRegex(run("terminal", "--help").stdout, r"(?m)^  put\s")
        self.assertNotRegex(run("terminal", "--help").stdout, r"(?m)^  pid\s")
        commands = internal.split("Flags:", 1)[0]
        self.assertRegex(commands, r"(?m)^  dev\s")
        self.assertRegex(commands, r"(?m)^  internal\s")
        for removed in ["pi", "opencode", "integration-event", "agent-worker"]:
            self.assertNotRegex(result.stdout, rf"(?m)^  {removed}\s")
        internal_help = run("internal", "--help")
        self.assertEqual(internal_help.returncode, 0, internal_help.stderr)
        for command in ("agent-hook-integrate", "agent-worker"):
            with self.subTest(command=command):
                self.assertIn(command, internal_help.stdout)
                current = run("internal", command, "--help")
                self.assertEqual(current.returncode, 0, current.stderr)
        for args in [("internal", "integration-event"), ("agent-worker",)]:
            self.assertNotEqual(run(*args, "--help").returncode, 0)

    def test_native_integration_events_use_the_same_server_endpoint(self):
        for provider in ("pi", "opencode"):
            result, request = self.exchange(["internal", "agent-hook-integrate", "session-start", "--provider", provider],
                input=json.dumps({"event": "SessionStart", "session_id": "native-session", "pid": 123}),
                responder=lambda req: {"id": req["id"], "result": {"ok": True}})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(request["method"], "agent.event")
            self.assertEqual(request["params"]["provider"], provider)
            self.assertEqual(request["params"]["kind"], "agent")

    def test_completion_install(self):
        with tempfile.TemporaryDirectory(prefix="graffitty completion ") as directory:
            home = Path(directory)
            env = {
                "HOME": directory,
                "XDG_CONFIG_HOME": str(home / "config"),
                "XDG_DATA_HOME": str(home / "data"),
                "ZDOTDIR": str(home / "zsh config"),
                "ZSH": "",
                "ZSH_CUSTOM": "",
            }
            paths = {
                "zsh": home / ".zsh/completions/_gft",
                "bash": home / "data/bash-completion/completions/gft",
                "fish": home / "config/fish/completions/gft.fish",
            }
            for shell, path in paths.items():
                with self.subTest(shell=shell):
                    result = run("integrate", "completion", "install", shell, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    script = path.read_text()
                    self.assertIn("gft", script)
                    self.assertIn("__complete_word__", script)
                    self.assertNotIn("usage complete-word", script)
                    if shell in ("bash", "zsh") and shutil.which(shell):
                        syntax_args = ["bash", "-O", "extglob", "-n"] if shell == "bash" else ["zsh", "-n"]
                        checked = subprocess.run([*syntax_args, str(path)], capture_output=True, text=True)
                        self.assertEqual(checked.returncode, 0, checked.stderr)
                    before = path.stat().st_mtime_ns
                    result = run("integrate", "completion", "install", shell, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(path.stat().st_mtime_ns, before)
                    path.write_text("custom completion")
                    result = run("integrate", "completion", "install", shell, env=env)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("--force", result.stderr)
                    self.assertEqual(path.read_text(), "custom completion")
                    result = run("integrate", "completion", "install", shell, "--force", env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(path.read_text(), script)
            self.assertFalse((home / "zsh config/.zshrc").exists())
            self.assertFalse((home / ".bashrc").exists())
            self.assertNotEqual(run("integrate", "completion", "install", "invalid", env=env).returncode, 0)

    def test_completion_candidates_without_usage_cli(self):
        for shell in ("zsh", "bash", "fish"):
            for line, expected in (("gft ", "integrate"),
                                   ("gft ch", "chromium"),
                                   ("gft chromium ", "new"),
                                   ("gft integrate ", "completion"),
                                   ("gft integrate ", "agent"),
                                   ("gft integrate agent ", "claude"),
                                   ("gft integrate completion ", "install"),
                                   ("gft integrate completion install ", "zsh")):
                with self.subTest(shell=shell, line=line):
                    result = run("__complete_word__", "--shell", shell,
                                 "--line", line, env={"PATH": ""})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(expected, result.stdout)
                    self.assertNotIn("Invalid usage config", result.stderr)

    @unittest.skipUnless(shutil.which("zsh"), "zsh required")
    def test_completion_install_oh_my_zsh(self):
        with tempfile.TemporaryDirectory(prefix="graffitty omz ") as directory:
            home = Path(directory)
            omz = home / ".oh-my-zsh"
            omz.mkdir()
            (omz / "oh-my-zsh.sh").write_text("# fixture\n")
            dotdir = home / "zsh config"
            dotdir.mkdir()
            env = {"HOME": directory, "ZDOTDIR": str(dotdir), "ZSH": "", "ZSH_CUSTOM": ""}
            for custom in ("$ZSH/custom", "$HOME/custom config"):
                (dotdir / ".zshrc").write_text(
                    'ZSH="$HOME/.oh-my-zsh"\n'
                    f'ZSH_CUSTOM="{custom}"\n'
                    'fpath=("$ZSH_CUSTOM/completions" $fpath)\n'
                )
                result = run("integrate", "completion", "install", "zsh", env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = omz / "custom" if custom == "$ZSH/custom" else home / "custom config"
                self.assertTrue((expected / "completions/_gft").is_file())
                self.assertIn("no .zshrc changes needed", result.stdout)
                self.assertFalse((home / ".zsh/completions/_gft").exists())

    def test_graph_requests(self):
        for args, method, params in [
            (["graph", "list"], "graph.list", {}),
            (["graph", "adjacent"], "graph.adjacent", {}),
            (["graph", "spawn", "--provider", "claude"], "graph.spawn", {"provider": "claude"}),
            (["graph", "spawn", "--provider", "pi", "--side", "right", "--of", "%3"], "graph.spawn", {"provider": "pi", "side": "right", "of": "%3"}),
            (["pane", "run", "--name", "build", "--side", "below", "cargo", "build", "--release"], "terminal.run", {"name": "build", "side": "below", "command": "cargo build --release"}),
            (["pane", "run", "--agent", "codex", "--model", "gpt-6", "--agent-arg=--no-daemon", "--outlive-parent", "--at", "40,900", "--size", "600x300"], "terminal.run", {"agent": "codex", "model": "gpt-6", "agent_args": ["--no-daemon"], "outlive_parent": True, "x": 40.0, "y": 900.0, "width": 600.0, "height": 300.0}),
            (["pane", "run"], "terminal.run", {}),
            (["pane", "place", "--target", "%8", "--side", "below", "--of", "%7"], "pane.place", {"target": "%8", "side": "below", "of": "%7"}),
            (["graph", "connect", "--from", "%1", "--to", "%2", "--turn-completed"], "graph.connect", {"from": "%1", "to": "%2", "read": False, "send": False, "turn_completed": True, "muted": False, "from_port": "", "to_port": ""}),
            (["graph", "read", "--node", "%1"], "graph.read", {"node": "%1"}),
            (["graph", "read", "--node", "%1", "--offset", "32"], "graph.read", {"node": "%1", "offset": 32}),
            (["graph", "send", "--to", "%2", "--text", "approved", "--run-id", "test"], "graph.send", {"to": "%2", "text": "approved", "run_id": "test"}),
        ]:
            result, request = self.exchange(args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(request["method"], method)
            self.assertEqual(request["params"], params)

    def test_pane_targets_and_pid_requests(self):
        cases = [
            (["pane", "list"], "pane.list", {}),
            (["pane", "pid"], "terminal.pid", {"details": False}),
            (["pane", "pid", "%3", "--details"], "terminal.pid", {"target": "%3", "details": True}),
            (["pane", "pid", "@7"], "terminal.pid", {"target": "@7", "details": False}),
            (["pane", "pid", ":2.1"], "terminal.pid", {"target": ":2.1", "details": False}),
            (["terminal", "get-text", "--target", "%3", "--json"], "terminal.get_text", {"target": "%3", "scrollback": False}),
            (["terminal", "send-key", "--target", "%3", "Enter"], "terminal.press", {"target": "%3", "key": "Enter"}),
            (["terminal", "send-key", "Ctrl+h", "--no-effects", "--target", "%3"], "terminal.press", {"target": "%3", "key": "Ctrl+h", "effects": False}),
            (["tab", "rename", "--target", "@7", "Build"], "tab.set_title", {"target": "@7", "title": "Build"}),
            (["chromium", "snapshot", "--target", "%8"], "chromium.snapshot", {"chromium": "%8"}),
            (["graph", "read", "--node", "%3"], "graph.read", {"node": "%3"}),
        ]
        for args, method, params in cases:
            with self.subTest(args=args):
                result, request = self.exchange(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(request["method"], method)
                self.assertEqual(request["params"], params)
        result = run("tab", "rename", "--target", "@7", "--tab", "2", "Build")
        self.assertNotEqual(result.returncode, 0)

    def test_lifecycle_hook_returns_graph_context(self):
        result, request = self.exchange(["internal", "agent-hook-integrate", "session-start", "--provider", "claude"], input=json.dumps({"hook_event_name": "SessionStart", "session_id": "test-session", "transcript_path": "/tmp/test.jsonl"}), responder=lambda req: {"id": req["id"], "result": {"adjacent": {"incoming": [], "outgoing": []}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request["method"], "agent.event")
        self.assertIn("graph adjacent", json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"])

    def test_hook_registers_each_provider_home(self):
        for provider, variable in [("claude", "CLAUDE_CONFIG_DIR"), ("codex", "CODEX_HOME")]:
            for account in ["work", "personal"]:
                directory = f"/tmp/{provider} {account}"
                result, request = self.exchange(
                    ["internal", "agent-hook-integrate", "session-start", "--provider", provider],
                    input=json.dumps({"hook_event_name": "SessionStart", "session_id": account, "transcript_path": directory + "/session.jsonl"}),
                    extra_env={variable: directory, "GRAFFITTY_AGENT_PID": "123"},
                    foreground=provider,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(request["params"]["provider_home"], directory)
                self.assertEqual(request["params"]["transcript_path"], directory + "/session.jsonl")
                self.assertNotEqual(request["params"]["pid"], 123)  # stale inherited PID is ignored

    def test_get_text_plain_json_and_errors(self):
        text = "한글 terminal\nlast line"
        reply = lambda req: {"id": req["id"], "result": {"text": text}}
        for prefix in [["terminal", "get-text"]]:
            result, request = self.exchange(prefix, responder=reply)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, text)
            self.assertEqual(request["method"], "terminal.get_text")
            self.assertEqual(request["params"], {"scrollback": False})
            result, request = self.exchange([*prefix, "--scrollback", "--json"], responder=reply)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["result"]["text"], text)
            self.assertEqual(request["params"], {"scrollback": True})
        result, _ = self.exchange(["terminal", "get-text"], responder=lambda req: {
            "id": req["id"], "error": {"code": "capture_failed", "message": "not ready"}
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("capture_failed", result.stderr)

    def test_launch_cwd_is_resolved_before_changing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / "tools/gft-gui"
            binary.parent.mkdir()
            shutil.copy2(BIN, binary)
            (root / "project.godot").touch()
            (root / "mise.toml").touch()
            launcher = root / "tools/mise"
            launcher.write_text('#!/bin/sh\nshift 5\nprintf "%s\\n" "$@"\n')
            launcher.chmod(0o755)
            directory = root / "directory with spaces"
            directory.mkdir()
            for prefix in [[]]:
                for value in [str(directory), os.path.relpath(directory)]:
                    with self.subTest(prefix=prefix, value=value):
                        result = run(*prefix, "--cwd", value, binary=binary)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), f"--cwd={directory.resolve()}")
            for value in [str(root / "missing"), str(launcher)]:
                result = run("--cwd", value, binary=binary)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--cwd is not a directory", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_tiling_command_names_and_request_shapes(self):
        for args, method, params in [
            (["status"], "status", {}),
            (
                ["layout", "floating", "tiling"],
                "layout",
                {"layouts": ["floating", "tiling"]},
            ),
            (["layout", "h_tiles"], "layout", {"layouts": ["h_tiles"]}),
            (["focus", "left"], "focus", {"direction": "left"}),
            (["move", "down"], "move", {"direction": "down"}),
            (["join-with", "right"], "join-with", {"direction": "right"}),
            (["split", "opposite"], "split", {"orientation": "opposite"}),
            (["balance-sizes"], "balance-sizes", {}),
            (["view", "overview"], "view", {"mode": "overview"}),
            (["new-window"], "new-window", {}),
        ]:
            with self.subTest(args=args):
                result, request = self.exchange(["tiling", *args])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(request["method"], "tiling." + method)
                self.assertEqual(request["params"], params)

    def test_tiling_rejects_unsupported_modes_before_connecting(self):
        for args in [
            ["layout"],
            ["layout", "accordion"],
            ["focus", "diagonal"],
            ["view", "anything"],
        ]:
            with self.subTest(args=args):
                result = run("tiling", *args)
                self.assertNotEqual(result.returncode, 0)

    def exchange(self, args, responder=None, input=None, extra_env=None, foreground=None):
        with tempfile.TemporaryDirectory(prefix="alm-cli-", dir="/tmp") as tmp:
            endpoint = str(Path(tmp) / "api.sock")
            received, failures = [], []
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(endpoint)
                server.listen(1)
                server.settimeout(4)

                def worker():
                    try:
                        with server.accept()[0] as client:
                            request = json.loads(client.makefile("rb").readline())
                            received.append(request)
                            response = (
                                responder(request)
                                if responder
                                else {"id": request["id"], "result": {"ok": True}}
                            )
                            client.sendall(
                                response
                                if isinstance(response, bytes)
                                else (json.dumps(response) + "\n").encode()
                            )
                    except (OSError, ValueError, KeyError) as exc:
                        failures.append(str(exc))

                thread = threading.Thread(target=worker)
                thread.start()
                result = run(
                    *args,
                    foreground=foreground,
                    input=input,
                    env={
                        **(extra_env or {}),
                        "GRAFFITTY_SOCKET": endpoint,
                        "GRAFFITTY_TOKEN": "test-capability",
                    },
                )
                thread.join(5)
            self.assertFalse(failures, (failures, result.stderr))
            self.assertEqual(received[0]["token"], "test-capability")
            self.assertEqual(received[0]["version"], 1)
            request_id = received[0]["id"]
            self.assertEqual(str(uuid.UUID(request_id)), request_id)
            self.assertEqual(uuid.UUID(request_id).version, 4)
            return result, received[0]

    def test_all_command_mappings(self):
        cases = [
            (["identify"], "identify", {}),
            (["pane", "list"], "pane.list", {}),
            (["chromium", "layout"], "workspace.layout", {"ratio": 0.55}),
            (["rpc", "identify", "--params", "{}"], "identify", {}),
            (
                ["terminal", "type", "--text", "한🙂"],
                "terminal.type",
                {"text": "한🙂", "interval_ms": 50},
            ),
            (
                ["terminal", "send-key", "Ctrl+u"],
                "terminal.press",
                {"key": "Ctrl+u"},
            ),
            (["chromium", "list"], "chromium.list", {}),
            (["chromium", "new"], "chromium.create", {"url": "about:blank"}),
        ]
        for verb, flags, params in [
            (
                "navigate",
                ["--url", "https://example.com"],
                {"url": "https://example.com"},
            ),
            ("snapshot", [], {}),
            ("click", ["--ref", "g1:e2"], {"ref": "g1:e2"}),
            (
                "fill",
                ["--ref", "g1:e2", "--text", "hello world"],
                {"ref": "g1:e2", "text": "hello world"},
            ),
            ("press", ["--key", "Enter"], {"key": "Enter"}),
            ("scroll", ["--x", "-12.5"], {"x": -12.5, "y": 500}),
            (
                "eval",
                ["--expression", "document.title"],
                {"expression": "document.title"},
            ),
            (
                "wait",
                ["--selector", "input"],
                {"selector": "input", "timeout_ms": 10000},
            ),
            ("present", ["--mode", "embedded"], {"mode": "embedded"}),
            ("select", [], {}),
            ("close", [], {}),
        ]:
            cases.append(
                (
                    ["chromium", verb, "--target", "%3", *flags],
                    "chromium." + verb,
                    {"chromium": "%3", **params},
                )
            )
        for args, method, params in cases:
            with self.subTest(args=args):
                result, request = self.exchange(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    (request["method"], request["params"]), (method, params)
                )

    def test_help_spec_and_guide_work_without_app(self):
        for args in [
            ("--help",),
            ("--version",),
            ("node", "parallel", "--help"),
            ("chromium", "fill", "--help"),
            ("__usage_spec__",),
            ("skill",),
            ("skill", "graph"),
            ("skill", "chromium"),
            ("pane", "run", "--help"),
            ("pane", "place", "--help"),
        ]:
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout)
        chromium = run("skill", "chromium").stdout
        self.assertIn("Graffitty", chromium)
        self.assertIn("gft chromium new", chromium)
        self.assertIn("@graffitty/playwright", chromium)
        self.assertNotIn("gft browser", chromium)
        self.assertIn("gft pane run --agent", run("skill", "graph").stdout)
        listing = run("skill").stdout
        self.assertIn("graph", listing)
        self.assertNotEqual(run("skill", "agents").returncode, 0)
        self.assertIn("chromium", listing)
        # Renamed entry points are removed, not aliased.
        for removed in [("guide",), ("--skill",), ("skill", "nope")]:
            with self.subTest(removed=removed):
                self.assertNotEqual(run(*removed).returncode, 0)
        for args in [("run", "--model", "x", "echo"), ("run", "--agent", "pi", "echo"), ("run", "--at", "nope"), ("place", "--size", "12")]:
            with self.subTest(args=args):
                self.assertNotEqual(run(*args).returncode, 0)
        self.assertIn("cmd node", run("__usage_spec__").stdout)
        self.assertIn("cmd chromium", run("__usage_spec__").stdout)
        self.assertNotIn("cmd browser", run("__usage_spec__").stdout)

    def test_invalid_input_and_missing_context(self):
        self.assertEqual(
            json.loads(run("identify").stdout)["error"]["code"],
            "missing_context",
        )
        for args in [
            ["chromium", "fill", "--target", "%3"],
            ["chromium", "present", "--target", "%3", "--mode", "oops"],
            ["terminal", "type", "--text", "hi", "--interval-ms", "abc"],
            ["not-a-command"],
            ["browser", "list"],
        ]:
            with self.subTest(args=args):
                self.assertEqual(run(*args).returncode, 2)
        for args in [
            ["rpc", "identify", "--params", "[]"],
            ["rpc", "identify", "--params", "{"],
            ["chromium", "layout", "--ratio", "NaN"],
            ["terminal", "type", "--text", "hi", "--interval-ms", "-1"],
            ["chromium", "wait", "--target", "%3", "--timeout-ms", "0"],
        ]:
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    json.loads(result.stdout)["error"]["code"], "invalid_params"
                )

    def test_host_errors_and_transport_validation(self):
        for responder, code in [
            (
                lambda r: {
                    "id": r["id"],
                    "error": {"code": "unauthorized", "message": "Denied"},
                },
                "unauthorized",
            ),
            (lambda r: {"id": "wrong", "result": {}}, "transport_error"),
            (lambda r: b'{"invalid":', "transport_error"),
        ]:
            with self.subTest(code=code):
                result, _ = self.exchange(["identify"], responder)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["error"]["code"], code)

    def test_mcp_stdio_preserves_scope_and_notifications(self):
        messages = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18"},
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "workspace_chromium",
                    "arguments": {"method": "identify"},
                },
            },
        ]
        result, request = self.exchange(
            ["mcp"], input="".join(json.dumps(m) + "\n" for m in messages)
        )
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["id"] for r in replies], [1, 2, 3])
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "graffitty")
        self.assertEqual(replies[1]["result"]["tools"][0]["name"], "workspace_chromium")
        self.assertFalse(replies[2]["result"]["isError"])
        self.assertEqual(request["method"], "identify")
        malformed = run("mcp", input="not json\n[]\n")
        self.assertEqual(
            [json.loads(l)["error"]["code"] for l in malformed.stdout.splitlines()],
            [-32700, -32600],
        )

    def test_dispatch_without_starting_godot(self):
        with tempfile.TemporaryDirectory(prefix="alm-dispatch-") as tmp:
            # The launcher follows the gft-gui link, so paths come back resolved.
            root = Path(tmp).resolve()
            (root / "tools").mkdir()
            binary = root / "tools/gft"
            shutil.copy2(BIN, binary)
            # As installed: gft-gui is a link to gft, not a second copy.
            gui = root / "tools/gft-gui"
            gui.symlink_to("gft")
            (root / "project.godot").touch()
            (root / "mise.toml").touch()
            launcher = root / "tools/mise"
            launcher.write_text('#!/bin/sh\nshift 5\nprintf "GUI:%s\\n" "$@"\n')
            launcher.chmod(0o755)
            self.assertIn("Usage: gft", run(binary=binary).stdout)
            self.assertEqual(run(binary=gui).stdout, "GUI:\n")
            result = run("--", "--plugin=/tmp/custom world.pck", binary=gui)
            self.assertEqual(result.stdout, "GUI:--plugin=/tmp/custom world.pck\n")
            # `gft gui` is the same launcher; Windows' gft-gui script runs it.
            result = run("gui", "--", "--plugin=/tmp/custom world.pck", binary=binary)
            self.assertEqual(result.stdout, "GUI:--plugin=/tmp/custom world.pck\n")
            result = run("identify", binary=binary)
            self.assertNotIn("GUI:", result.stdout)
            self.assertEqual(
                json.loads(result.stdout)["error"]["code"], "missing_context"
            )
            # The distribution layout delegates to Godot and the host PCK.
            launcher.unlink()
            (root / "project.godot").unlink()
            (root / "mise.toml").unlink()
            (root / "terminal.pck").touch()
            fake = root / "fake-godot"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake.chmod(0o755)
            result = run(
                "--",
                "--plugin=bistro.pck",
                binary=gui,
                env={
                    "GRAFFITTY_GODOT": str(fake),
                    "XDG_STATE_HOME": str(root / "state"),
                    "XDG_CONFIG_HOME": str(root / "config"),
                },
            )
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    "--path",
                    str(root),
                    "--log-file",
                    str(root / "state/graffitty/graffitty.log"),
                    "--main-pack",
                    str(root / "terminal.pck"),
                    "--",
                    "--plugin=bistro.pck",
                ],
            )
            settings = root / "config/graffitty/override.cfg"
            settings.parent.mkdir(parents=True)
            settings.write_text("[application]\nboot_splash/show_image=true\n")
            env = {
                "GRAFFITTY_GODOT": str(fake),
                "XDG_STATE_HOME": str(root / "state"),
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_CACHE_HOME": str(root / "cache"),
            }
            result = run(binary=gui, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = result.stdout.splitlines()
            cached = Path(argv[argv.index("--main-pack") + 1])
            self.assertTrue(cached.is_relative_to(root / "cache/graffitty/startup"))
            self.assertEqual(cached.resolve(), (root / "terminal.pck").resolve())
            self.assertEqual(
                (cached.parent / "override.cfg").resolve(), settings.resolve()
            )
            self.assertFalse((root / "override.cfg").exists())
            self.assertEqual(run(binary=gui, env=env).stdout, result.stdout)
            settings.unlink()
            argv = run(binary=gui, env=env).stdout.splitlines()
            self.assertEqual(
                argv[argv.index("--main-pack") + 1], str(root / "terminal.pck")
            )

    def test_bundled_runtime_needs_no_external_godot(self):
        with tempfile.TemporaryDirectory(prefix="alm-bundle-") as tmp:
            contents = Path(tmp) / "Graffitty.app/Contents"
            macos = contents / "MacOS"
            resources = contents / "Resources/graffitty"
            macos.mkdir(parents=True)
            (resources / "tools").mkdir(parents=True)
            (resources / "terminal.pck").touch()
            runtime = macos / "GraffittyRuntime"
            runtime.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            runtime.chmod(0o755)
            for binary in [macos / "Graffitty", resources / "tools/gft-gui"]:
                shutil.copy2(BIN, binary)
                result = run(
                    binary=binary,
                    env={
                        "XDG_STATE_HOME": str(Path(tmp) / "state"),
                        "XDG_CONFIG_HOME": str(Path(tmp) / "config"),
                    },
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.splitlines(),
                    [
                        "--log-file",
                        str(Path(tmp) / "state/graffitty/graffitty.log"),
                        "--",
                    ],
                )


if __name__ == "__main__":
    unittest.main()
