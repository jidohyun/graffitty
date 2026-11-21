"""Keep development windows in one application (and one remote listener)."""

import fcntl
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


def open_window(descriptor: Path, args: list[str], timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while True:
        submitted = False
        try:
            data = json.loads(descriptor.read_text())
            with socket.socket(socket.AF_UNIX) as probe:
                probe.settimeout(2)
                probe.connect(data["socket"])
                probe.sendall(json.dumps({"version": 1, "id": "launch-info", "token": data["token"],
                                         "method": "application.launch_info", "params": {}}).encode() + b"\n")
                with probe.makefile("rb") as response:
                    info = json.loads(response.readline(65536))
                if not info.get("result", {}).get("fresh_sessions"):
                    raise RuntimeError("The running GUI uses older startup code. Close its GUI windows and run again; server sessions remain running.")
                if "--reload" in args and not info.get("result", {}).get("script_reload"):
                    raise RuntimeError("The running GUI has no source watcher. Detach its windows, then run mise dev --reload; server sessions remain running.")
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(2)
                connection.connect(data["socket"])
                request = {
                    "version": 1,
                    "id": "launch",
                    "token": data["token"],
                    "method": "application.open_window",
                    "params": {
                        "fresh_session": True,
                        "args": args,
                        "cwd": os.environ.get("GRAFFITTY_INITIAL_PWD") or os.getcwd(),
                    },
                }
                connection.sendall(json.dumps(request).encode() + b"\n")
                submitted = True
                with connection.makefile("rb") as response:
                    result = json.loads(response.readline(65536))
                if "error" in result:
                    if result["error"].get("code") == "busy":
                        submitted = False
                        raise OSError(result["error"]["message"])
                    raise RuntimeError(str(result["error"]))
                return
        except (OSError, ValueError, KeyError) as error:
            if submitted:
                # A lost reply does not mean the window was not created.
                raise RuntimeError(
                    "Graffitty did not acknowledge the new-window request"
                ) from error
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    "Graffitty is running but did not answer the new-window request"
                ) from error
            time.sleep(0.05)


def run(command: list[str], directory: Path) -> int:
    directory.mkdir(parents=True, exist_ok=True)
    descriptor = directory / "dev-instance.json"
    with (directory / "dev-instance.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            args = command[command.index("--") + 1 :] if "--" in command else []
            allowed = ("--workspace=", "--cwd=", "--working-directory=", "--shell=")
            if any(arg not in ("--attach-session", "--reload") and not arg.startswith(allowed) for arg in args):
                raise RuntimeError("Close the running GUI before changing rendering or configuration startup options.")
            open_window(descriptor, args)
            print(
                "[dev] Opened a window in the running Graffitty (shared remote listener)."
            )
            return 0
        descriptor.unlink(missing_ok=True)
        log = directory / "graffitty.log"
        if log.is_file():
            shutil.copyfile(log, log.with_suffix(".log.1"))
        if "--" not in command:
            command.append("--")
        command.append(f"--launch-descriptor={descriptor}")
        child = subprocess.Popen(command)
        handlers = {}

        def forward(signum, _frame):
            if child.poll() is None:
                child.send_signal(signum)

        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[signum] = signal.signal(signum, forward)
        try:
            result = child.wait()
            return result if result >= 0 else 128 - result
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
            descriptor.unlink(missing_ok=True)


def main() -> int:
    base = Path(os.environ.get("XDG_STATE_HOME", ""))
    if not base.is_absolute():
        base = Path.home() / ".local/state"
    try:
        return run(sys.argv[1:], base / "graffitty")
    except RuntimeError as error:
        print(f"[dev] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
