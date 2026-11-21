"""Record two production Windows launches separated by natural owner shutdown."""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tools",)]
from av1 import check_encoder


class ProcessHandle:
    """Keep the original process identity through exit; never probe with kill(0)."""
    def __init__(self, pid):
        self.pid = pid
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.api.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        self.api.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        times = [wintypes.FILETIME() for _ in range(4)]
        if not self.api.GetProcessTimes(self.handle, *(ctypes.byref(value) for value in times)):
            self.api.CloseHandle(self.handle)
            raise ctypes.WinError(ctypes.get_last_error())
        self.birth = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime

    def exited(self, timeout_ms=0):
        result = self.api.WaitForSingleObject(self.handle, timeout_ms)
        if result not in (0, 258):
            raise ctypes.WinError(ctypes.get_last_error())
        return result == 0

    def cleanup(self):
        if not self.exited():
            self.api.TerminateProcess(self.handle, 1)
            self.exited(5000)
        self.api.CloseHandle(self.handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GRAFFITTY_GODOT"))
    parser.add_argument("--shell", choices=("powershell.exe", "pwsh.exe"), default="pwsh.exe")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test requires the interactive Windows desktop")
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    binary = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "dist/bin/gft.exe")).resolve()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
    env.update({f"XDG_{kind}_HOME": str(directory / kind.lower())
                for kind in ("CONFIG", "STATE", "CACHE", "DATA")})
    descriptor = directory / "state/graffitty/server.json"
    env.update(GRAFFITTY_SERVER=str(binary), GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor),
               GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_AV1_PRESET="10")
    env.setdefault("MISE_DATA_DIR", str(Path(env["LOCALAPPDATA"]) / "mise"))
    config = directory / "config/graffitty"
    config.mkdir(parents=True)
    (config / "server.toml").write_text(
        "[terminal]\nshell = " + json.dumps([args.shell, "-NoLogo", "-NoProfile"]) +
        "\nshell_integration = true\n", encoding="utf-8")
    report = {"shell": args.shell, "cli_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "godot": args.godot, "cycles": []}
    for cycle in (1, 2):
        output = directory / str(cycle)
        output.mkdir()
        assert not descriptor.exists(), "No stale descriptor may remain before a normal launch"
        env.update(GRAFFITTY_RELAUNCH_EVIDENCE=str(output), GRAFFITTY_RELAUNCH_CYCLE=str(cycle))
        watched = []
        with (output / "godot.log").open("w", encoding="utf-8") as log:
            frontend = subprocess.Popen([args.godot, "--path", str(ROOT / "frontends/godot/project"),
                "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                "--script", "res://tests/windows_relaunch_smoke.gd", "--", "--no-plugin"],
                env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 35
                owner = None
                while not (output / "ready.json").exists():
                    if owner is None and descriptor.exists():
                        try:
                            identity = json.loads(descriptor.read_text(encoding="utf-8"))
                        except json.JSONDecodeError:
                            continue
                        owner = ProcessHandle(identity["pid"])
                        watched.append(owner)
                    assert frontend.poll() is None, "Frontend exited before startup completed"
                    assert time.monotonic() < deadline, "Normal frontend startup timed out"
                    time.sleep(.02)
                ready = json.loads((output / "ready.json").read_text(encoding="utf-8"))
                assert owner is not None, "Frontend must create its own local server"
                shell = ProcessHandle(ready["shell_pid"])
                watched.append(shell)
                assert not owner.exited() and not shell.exited()
                ready.update(server_pid=owner.pid, server_birth=owner.birth, shell_birth=shell.birth)
                if report["cycles"]:
                    previous = report["cycles"][-1]
                    assert (owner.pid, owner.birth) != (previous["server_pid"], previous["server_birth"])
                    assert (shell.pid, shell.birth) != (previous["shell_pid"], previous["shell_birth"])
                (output / "close").touch()
                assert frontend.wait(timeout=20) == 0, "Frontend must exit normally"
                assert owner.exited(5000), "Owner must stop naturally before cleanup"
                assert shell.exited(5000), "Original shell must exit before cleanup"
                assert not descriptor.exists(), "Closed owner must remove its descriptor"
                time.sleep(5)
                assert not descriptor.exists(), "No reconnect loop may restart the owner"
                ready["natural_shutdown"] = True
                report["cycles"].append(ready)
                (directory / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
            finally:
                if frontend.poll() is None:
                    frontend.kill()
                    frontend.wait(timeout=5)
                for process in reversed(watched):
                    process.cleanup()
    print("WINDOWS_RELAUNCH_PASS", directory)


if __name__ == "__main__":
    main()
