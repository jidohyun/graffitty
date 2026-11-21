"""Opt-in restart of the local session owner before launching development UI."""

import json
import os
import subprocess
import sys
from pathlib import Path


def descriptor_path(env, args):
    for arg in reversed(args):
        if arg.startswith("--session-connection="):
            return Path(arg.split("=", 1)[1]).absolute()
    if env.get("GRAFFITTY_SERVER_DESCRIPTOR"):
        return Path(env["GRAFFITTY_SERVER_DESCRIPTOR"]).absolute()
    base = Path(env.get("XDG_STATE_HOME", ""))
    if not base.is_absolute():
        base = (Path(env["LOCALAPPDATA"]) if os.name == "nt"
                else Path.home() / ".local/state")
    return base / "graffitty/server.json"


def running_server(binary, descriptor, env):
    if not descriptor.is_file():
        return None
    # --status checks the live descriptor lock, not just a possibly stale PID.
    result = subprocess.run(
        [str(binary), "server", "--connection", str(descriptor), "--auth-file",
         str(descriptor.parent / "auth.json"), "--status"],
        env=env, capture_output=True, text=True, timeout=5,
    )
    if result.returncode:
        if "Server is not running" in result.stderr or not descriptor.is_file():
            return None
        raise RuntimeError("Could not check the running Graffitty server: " + result.stderr.strip())
    value = json.loads(result.stdout)
    if not isinstance(value.get("pid"), int) or value["pid"] <= 1 or value["pid"] == os.getpid():
        raise RuntimeError("Invalid PID in the running server descriptor")
    return value


def cli(binary, env, *args):
    result = subprocess.run(
        [str(binary), *args], env=env, capture_output=True, text=True, timeout=60,
    )
    if result.returncode:
        raise RuntimeError(
            f"gft {' '.join(args)} failed; launch canceled: "
            + (result.stderr.strip() or result.stdout.strip())
        )
    return result.stdout.strip()


def session_ids(binary, env):
    sessions = json.loads(cli(binary, env, "session", "list", "--json"))
    if not isinstance(sessions, list) or any(
        not isinstance(s, dict) or not isinstance(s.get("id"), str)
        or not s["id"].startswith("$") or not s["id"][1:].isdigit()
        for s in sessions
    ):
        raise RuntimeError("Invalid session list; launch canceled.")
    return {s["id"] for s in sessions}


def restart_if_requested(binary, descriptor, env):
    previous = running_server(binary, descriptor, env)
    if previous is None:
        return
    if not sys.stdin.isatty():
        print("[dev] Server already running; keeping it (no interactive terminal).", flush=True)
        return
    print("[dev] Server is running.\n"
          "  1. Keep running (default)\n"
          "  2. Restart server — keep terminals and programs running\n"
          "  3. Restart terminals with new build — end all existing sessions and programs")
    while True:
        try:
            answer = input("[dev] Choose [1/2/3, default 1]: ").strip()
        except EOFError:
            return
        if answer in ("", "1"):
            return
        if answer in ("2", "3"):
            break
        print("Please choose 1, 2 or 3.")
    if answer == "3":
        try:
            confirmation = input(
                "[dev] All existing sessions, shells and programs will end. "
                "A checkpoint saves the layout, not running programs. "
                "Type RESTART to continue: "
            ).strip()
        except EOFError:
            return
        if confirmation != "RESTART":
            print("[dev] Keeping the running server and terminals.", flush=True)
            return
    if running_server(binary, descriptor, env) != previous:
        print("[dev] Server changed while waiting; leaving the current owner alone.", flush=True)
        return
    # Route every command to the selected owner, never to an inherited pane
    # (which may be on a different local or remote server).
    command_env = dict(env, GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor))
    for key in ("GRAFFITTY_SOCKET", "GRAFFITTY_TOKEN"):
        command_env.pop(key, None)
    before = session_ids(binary, command_env)
    checkpoint = cli(binary, command_env, "checkpoint", "save")
    print("[dev] Checkpoint saved: " + checkpoint, flush=True)
    if running_server(binary, descriptor, env) != previous:
        raise RuntimeError("Server changed while saving the checkpoint; launch canceled.")
    # Unsupported or failed handovers abort. Never fall back to terminating
    # the server, even when a terminal reset was requested.
    result = cli(binary, command_env, "server", "restart")
    if not before.issubset(session_ids(binary, command_env)):
        raise RuntimeError("Sessions did not survive the restart; launch canceled.")
    print("[dev] " + result, flush=True)
    if answer == "2":
        return
    # Keep a fresh session alive while retiring the old ones so closing the
    # last old session cannot shut down the restarted server.
    #
    # The GUI attaches through its usual launch path; no checkpoint restore
    # replays old jobs.
    fresh = cli(binary, command_env, "session", "new", "-d")
    if fresh in before or not fresh.startswith("$") or not fresh[1:].isdigit():
        raise RuntimeError("Invalid fresh session; existing sessions were not closed.")
    for target in sorted(before):
        cli(binary, command_env, "session", "kill", "-t", target)
    remaining = session_ids(binary, command_env)
    if before & remaining or fresh not in remaining:
        raise RuntimeError("Could not verify fresh terminals; launch canceled.")
    print("[dev] Old sessions ended; fresh session " + fresh + " is ready.", flush=True)
