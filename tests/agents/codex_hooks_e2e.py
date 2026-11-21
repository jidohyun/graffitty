#!/usr/bin/env python3
"""Check the real Codex lifecycle with an isolated home, local mock model,
and private receiver.

    python3 tests/agents/codex_hooks_e2e.py local
    python3 tests/agents/codex_hooks_e2e.py daemon

Add `--graph` to check automatic discovery, native lifecycle, and draft
preservation.

Requires Codex 0.158 or newer with a complete local CLI (npm, bun, or
standalone). The test installs a private daemon package from that CLI.

It uses the local mock model and private receiver for all requests and
messages. Logs remain in the printed temporary folder.
"""

import shutil
import subprocess
import os, pty, fcntl, termios, struct, socket, tempfile, threading, json, time, select, signal, sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

repo = Path(__file__).resolve().parents[2]
mode = sys.argv[1] if len(sys.argv) > 1 else "local"
assert mode in ("local", "daemon", "overrides")
d = Path(tempfile.mkdtemp(prefix="acx-", dir="/tmp")).resolve()
os.chmod(d, 0o700)
home = d / "codex"
home.mkdir()
(d / "work").mkdir()


def stop_private_daemon():
    # New Codex stores JSON PID records. Use its explicit-home control endpoint
    # instead of assuming an integer PID file or discovering an ambient daemon.
    if (home / "app-server-control/app-server-control.sock").exists():
        subprocess.run([shutil.which("codex"), "app-server", "daemon", "stop"],
                       env={**os.environ, "CODEX_HOME": str(home)}, check=True,
                       stdout=subprocess.DEVNULL, timeout=15)


def remove_private_package():
    # The daemon package Codex installs here is a ~300 MB copy of the CLI; keep only logs.
    shutil.rmtree(home / "packages", ignore_errors=True)


class Mock(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if (d / "work" / "hold-response").exists():
            (d / "work" / "response-held").touch()
            until = time.monotonic() + 20
            while (d / "work" / "hold-response").exists() and time.monotonic() < until:
                time.sleep(0.05)
        msg = {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "OK", "annotations": []}],
        }
        events = [
            {
                "type": "response.created",
                "response": {"id": "resp_test", "status": "in_progress", "output": []},
            },
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": dict(msg, content=[], status="in_progress"),
            },
            {"type": "response.output_item.done", "output_index": 0, "item": msg},
            {
                "type": "response.completed",
                "response": {
                    "id": "resp_test",
                    "status": "completed",
                    "output": [msg],
                    "usage": {
                        "input_tokens": 10,
                        "output_tokens": 1,
                        "total_tokens": 11,
                    },
                },
            },
        ]
        body = "".join(
            "event: " + v["type"] + "\ndata: " + json.dumps(v) + "\n\n" for v in events
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


mock = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
threading.Thread(target=mock.serve_forever, daemon=True).start()
(home / "config.toml").write_text(
    'check_for_update_on_startup = false\nmodel = "gpt-6-sol"\nmodel_provider = "mock"\n[model_providers.mock]\nname = "mock"\nbase_url = "http://127.0.0.1:'
    + str(mock.server_port)
    + '/v1"\nwire_api = "responses"\n[projects."'
    + str(d / "work")
    + '"]\ntrust_level = "trusted"\n'
)

# Graph discovery must work without hooks or launch interception.
if "--graph" not in sys.argv:
    subprocess.run([str(repo / "dist/bin/gft"), "integrate", "agent", "codex", "--apply"],
                   env={**os.environ, "CODEX_HOME": str(home)}, check=True)

# Install a private daemon package from the CLI under test. The install
# runs offline. `remove_private_package()` deletes it after the test.
#
# Keep the real home's `packages` directory separate. Even without an
# update, the daemon rewrites `packages/app-server-daemon/current` to an
# absolute path under the temporary home. Sharing the directory would
# break the real account's daemon when that temporary path is removed.
(home / "auth.json").write_text('{"OPENAI_API_KEY":"test-key"}')
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
if "--graph" in sys.argv:
    import subprocess

    (d / "bin").mkdir()
    (d / "bin/gft").symlink_to(repo / "dist/bin/gft")
    shell_config = d / "zsh"
    shell_config.mkdir()
    (shell_config / ".zshrc").write_text(
        f'export PATH="{d / "bin"}:$PATH"\n'
        "alias cod='codex --dangerously-bypass-approvals-and-sandbox'\n"
    )
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GRAFFITTY_")}
    env.update(CODEX_HOME=str(home), ZDOTDIR=str(shell_config), GRAFFITTY_CODEX_TEST_MODE=mode,
               GRAFFITTY_CODEX_TEST_WORK=str(d / "work"))
    # The Godot client attaches to the server named by XDG_STATE_HOME (by
    # default the live one), and that server builds every pane's environment
    # from its own.
    #
    # Own a private server and private state instead; otherwise `cod` runs
    # under the real default account instead of this isolated CODEX_HOME,
    # inside terminals added to the live workspace.
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env["XDG_" + kind + "_HOME"] = str(d / "xdg" / kind.lower())
    from e2e_server import PrivateServer

    try:
        with PrivateServer(env, d, "/bin/zsh"):
            result = subprocess.run(
                ["godot", "--headless", "--path", str(repo / "frontends/godot/project"), "--script",
                 "tests/codex_graph_e2e.gd", "--", "--shell=/bin/zsh"],
                env=env, timeout=120,
            )
        if mode == "daemon":
            assert (home / "app-server-control/app-server-control.sock").exists(), "Expected real shared daemon"
        else:
            assert not (home / "app-server-control/app-server-control.sock").exists(), "--no-daemon must not start a shared daemon"
    finally:
        stop_private_daemon()
        remove_private_package()
    print("LOG HOME", home)
    sys.exit(result.returncode)

server = socket.socket(socket.AF_UNIX)
server.bind(str(d / "api.sock"))
server.listen()
events = []


def serve():
    while True:
        try:
            c, _ = server.accept()
            with c:
                req = json.loads(c.makefile().readline())
                events.append(req["params"])
                c.sendall(
                    (
                        json.dumps({"id": req["id"], "result": {"adjacent": {}}}) + "\n"
                    ).encode()
                )
        except OSError:
            return


threading.Thread(target=serve, daemon=True).start()
pid, fd = pty.fork()
if pid == 0:
    os.chdir(d / "work")
    # A new test TUI must not inherit the supervising Codex turn's identity.
    # The real session owner applies the same boundary when it spawns a PTY.
    for key in ("CODEX_THREAD_ID", "CODEX_SESSION_ID", "GRAFFITTY_CODEX_CONTEXT"):
        os.environ.pop(key, None)
    os.environ.update(
        CODEX_HOME=str(home),
        GRAFFITTY_SOCKET=str(d / "api.sock"),
        GRAFFITTY_TOKEN="test-capability",
        GRAFFITTY_BIN=str(repo / "dist/bin/gft"),
        TERM="xterm-256color",
        PATH=str(repo / "dist/bin") + ":" + os.environ["PATH"],
    )
    args = [shutil.which("codex"), "--dangerously-bypass-approvals-and-sandbox"]
    if mode == "local":
        args += ["--no-daemon"]
    if mode == "overrides":
        args += ["-c", 'default_permissions=":danger-full-access"']
    args += ["Say OK"]
    os.execv(args[0], args)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
out = b""
deadline = time.time() + 30
try:
    while time.time() < deadline and not any(e.get("event") == "Stop" for e in events):
        r, _, _ = select.select([fd], [], [], 0.25)
        if r:
            try:
                b = os.read(fd, 65536)
            except OSError:
                break
            out += b
            if b"\x1b[6n" in b:
                os.write(fd, b"\x1b[1;1R")
            if b"\x1b[c" in b:
                os.write(fd, b"\x1b[?1;2c")
    if mode == "daemon":
        assert (home / "app-server-control/app-server-control.sock").exists(), (
            "Daemon mode silently fell back to local"
        )
    assert all(
        e.get("transcript_path") and Path(e["transcript_path"]).is_file()
        for e in events if e.get("event") not in ("Launch", "Ready")
    ), "Missing session file"
    print(
        mode,
        "EVENTS",
        [(x.get("event"), x.get("session_id"), x.get("pid")) for x in events],
    )
finally:
    (d / "terminal.log").write_bytes(out)
    print("LOG", d / "terminal.log")
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == 0:
            os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    stop_private_daemon()
    remove_private_package()
    server.close()
sys.exit(
    0
    if ((mode == "local" and {"SessionStart", "UserPromptSubmit", "Stop"} <= {e.get("event") for e in events})
        or (mode == "daemon" and not events))
    else 1
)
