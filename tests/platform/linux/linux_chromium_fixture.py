#!/usr/bin/env python3
"""Private Linux server fixture for test_linux_chromium.py; never a production service."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def parent(pid):
    return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])


def belongs(pid, ancestor):
    seen = set()
    while pid > 1 and pid not in seen:
        if pid == ancestor:
            return True
        seen.add(pid)
        pid = parent(pid)
    return False


def process_arguments(pid):
    # Chromium's Linux process titles can flatten argv into a single string.
    return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").split()


def kill_owned(directory, host, kind):
    state = json.loads((directory / "fixture.json").read_text())
    server = state["pid"]
    assert Path(f"/proc/{server}/exe").resolve() == Path(state["server"])
    assert Path(f"/proc/{host}/exe").resolve() == Path(state["host"])
    assert belongs(host, server), "Browser does not belong to this test server"
    targets = [host] if kind == "host" else []
    if kind == "renderer":
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                pid = int(entry.name)
                args = process_arguments(pid)
                if (b"--type=renderer" in args and b"--extension-process" not in args
                        and belongs(pid, host)):
                    targets.append(pid)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
    assert targets, "No owned renderer found"
    for pid in targets:
        os.kill(pid, signal.SIGKILL)
    print(json.dumps({"killed": kind, "count": len(targets)}))


def serve(args):
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, GRAFFITTY_CHROMIUM_HOST=str(args.host.resolve()),
               GRAFFITTY_CHROMIUM_OZONE_PLATFORM=args.platform,
               GRAFFITTY_SERVER__CHROMIUM__BACKEND=args.backend,
               SHELL="/bin/sh", RUST_LOG="graffitty_video=debug")
    for kind in ("CONFIG", "STATE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    if args.platform == "wayland":
        env.pop("DISPLAY", None)
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    with (directory / "server.log").open("wb") as log:
        process = subprocess.Popen([
            str(args.server.resolve()), "server", "--listen", args.listen,
            "--connection", str(directory / "connection.json"),
            "--auth-file", str(directory / "auth.json"), "--shell", "/bin/sh",
        ], env=env, stdout=log, stderr=log, start_new_session=True)
        (directory / "fixture.json").write_text(json.dumps({
            "pid": process.pid, "server": str(args.server.resolve()), "host": str(args.host.resolve())}))
        deadline = time.monotonic() + 1200
        try:
            while process.poll() is None and not stopping and not (directory / "stop").exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("Fixture lifetime exceeded")
                time.sleep(.2)
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
            cgroups = Path(env.get("GODOT_RESOURCE_CGROUP_PARENT", "/sys/fs/cgroup"))
            leaked = [str(p) for p in cgroups.glob(f"godot-terminal-{process.pid}-*")]
            (directory / "cleanup.json").write_text(json.dumps({
                "pid": process.pid, "exit": process.returncode, "leaked_cgroups": leaked}))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    server = commands.add_parser("serve")
    server.add_argument("--directory", type=Path, required=True)
    server.add_argument("--server", type=Path, required=True)
    server.add_argument("--host", type=Path, required=True)
    server.add_argument("--platform", choices=["x11", "wayland"], required=True)
    server.add_argument("--backend", choices=["alloy", "chrome"], required=True)
    server.add_argument("--listen", required=True)
    kill = commands.add_parser("kill")
    kill.add_argument("--directory", type=Path, required=True)
    kill.add_argument("--host-pid", type=int, required=True)
    kill.add_argument("--kind", choices=["host", "renderer"], required=True)
    args = parser.parse_args()
    if args.action == "serve":
        serve(args)
    else:
        kill_owned(args.directory, args.host_pid, args.kind)


if __name__ == "__main__":
    main()
