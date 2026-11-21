"""Test: after an upgrade, the open window reopens as the new version.

Steps:
1. Start the Godot app (headless) with a private server.
2. Replace the server executable in place, as an installer does.
3. Run `gft internal update finish`.

Passes when:
- The old window closes by itself.
- A new window opens and resumes the same session.
- No second session appears and no terminal closes.

Run:

    uv run --no-project tests/godot/update_relaunch_e2e.py
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))
GODOT = os.environ.get("GODOT") or shutil.which("godot")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def main():
    # Keep this path short: Unix socket paths under it are limited to 104 bytes on macOS.
    root = Path(tempfile.mkdtemp(prefix="gftu", dir="/tmp"))
    cli = root / "bin/gft"
    cli.parent.mkdir()
    shutil.copy2(CLI, cli)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_", "TMUX", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    descriptor = root / "state/graffitty/server.json"
    env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor), GRAFFITTY_SERVER=str(cli), SHELL="/bin/sh")

    def processes():
        """Windows started by this run. Their environment contains this run's directory."""
        found = set()
        for pid in subprocess.run(["pgrep", "-f", "terminal.tscn"], capture_output=True, text=True).stdout.split():
            described = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
            if f"GRAFFITTY_SERVER_DESCRIPTOR={descriptor}" in described:
                found.add(int(pid))
        return found

    def gft(*args):
        result = subprocess.run([cli, *args], env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, f"gft {' '.join(args)}: {result.stdout}{result.stderr}"
        return result.stdout

    def wait(ready, what, seconds=60):
        deadline = time.monotonic() + seconds
        while True:
            try:
                value = ready()
            except (OSError, ValueError, AssertionError, subprocess.SubprocessError):
                value = None
            if value:
                return value
            assert time.monotonic() < deadline, f"Timed out waiting for {what}"
            time.sleep(.1)

    def server_pid():
        return json.loads(descriptor.read_text())["pid"]

    def sessions():
        return json.loads(gft("session", "list", "--json"))

    try:
        window = subprocess.Popen(
            [GODOT, "--headless", "--path", str(ROOT / "frontends/godot/project"), "res://scenes/terminal.tscn"],
            env=env, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait(lambda: len(sessions()) == 1 and sessions()[0]["attached"], "the window's session")
        first = server_pid()
        print("PASS the window started a server and a session")

        # Do what an installer does: put a new executable at the same path. The old process keeps running.
        staged = cli.with_name("gft.new")
        shutil.copy(CLI, staged)
        os.replace(staged, cli)
        assert "terminal(s) kept" in gft("internal", "update", "finish")
        wait(lambda: window.poll() is not None, "the replaced version's window to leave", 30)
        reopened = wait(lambda: processes() - {window.pid}, "a window of the installed version")
        assert server_pid() != first, "a new server owns the session"
        wait(lambda: sessions()[0]["attached"], "the reopened window to show the session")
        time.sleep(3)
        assert all(alive(pid) for pid in reopened), "the reopened window stays"
        assert len(sessions()) == 1, f"the reopened window resumed the session: {sessions()}"
        print("PASS the window reopened as the installed version and resumed its session")
    finally:
        for pid in processes():
            os.kill(pid, signal.SIGKILL)
        for pid in subprocess.run(["pgrep", "-f", str(root)], capture_output=True, text=True).stdout.split():
            os.kill(int(pid), signal.SIGKILL)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
