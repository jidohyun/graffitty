# /// script
# dependencies = ["psutil"]
# ///
"""Check the exported app in a logged-in Windows desktop (not a headless/SSH session).

uv run tests/platform/windows/windows_packaged_startup.py --bundle dist/windows
"""

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import psutil

sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/support", "tools")]
from check_godot import failed  # noqa: E402
from packaged_probe import write_probe  # noqa: E402


def require_interactive_desktop() -> None:
    """Reject SSH/service window stations before diagnosing GPU startup.

    A logged-in user elsewhere on the machine is not sufficient: this process
    must itself run in a visible window station in a non-service session.
    """
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32.ProcessIdToSessionId.argtypes = [wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    kernel32.ProcessIdToSessionId.restype = wintypes.BOOL
    user32.GetProcessWindowStation.argtypes = []
    user32.GetProcessWindowStation.restype = wintypes.HANDLE
    user32.GetUserObjectInformationW.argtypes = [
        wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
        wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
    ]
    user32.GetUserObjectInformationW.restype = wintypes.BOOL

    class UserObjectFlags(ctypes.Structure):
        _fields_ = [("inherit", wintypes.BOOL), ("reserved", wintypes.BOOL), ("flags", wintypes.DWORD)]

    session = wintypes.DWORD()
    flags = UserObjectFlags()
    needed = wintypes.DWORD()
    if not kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session)):
        raise ctypes.WinError(ctypes.get_last_error())
    station = user32.GetProcessWindowStation()
    if not station or not user32.GetUserObjectInformationW(
        station, 1, ctypes.byref(flags), ctypes.sizeof(flags), ctypes.byref(needed),
    ):  # UOI_FLAGS = 1; WSF_VISIBLE = 1.
        raise ctypes.WinError(ctypes.get_last_error())
    if session.value == 0 or not flags.flags & 1:
        raise RuntimeError(
            "BLOCKED: graphical startup requires the logged-in interactive desktop; "
            "this process is in an SSH/service or non-visible window station. "
            "Run locally or through a scheduled task with Interactive logon type. "
            "No application was launched; this is not a GPU startup failure."
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("dist/windows"))
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Run this test on the logged-in Windows desktop")
    require_interactive_desktop()
    bundle = args.bundle.resolve()
    with tempfile.TemporaryDirectory(prefix="graffitty-windows-startup-") as scratch:
        profile = Path(scratch)
        env = os.environ.copy()
        for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(profile / kind.lower())
        env["APPDATA"] = str(profile / "roaming")
        env["LOCALAPPDATA"] = str(profile / "local")
        probe = write_probe(profile / "startup-probe.gd", """
if DirAccess.dir_exists_absolute("res://worlds"):
	push_error("App pack must not contain external worlds")
for path in ["res://scenes/FlatTerminalSpaceWorld.gd", "res://scenes/Flat2DWorld.gd"]:
	if not ResourceLoader.exists(path):
		push_error("Missing built-in world: " + path)
""")
        started = time.time()
        try:
            # A server can inherit stdout. A file avoids waiting on an open pipe
            # after the frontend exits.
            log = profile / "stdout.log"
            with log.open("w", encoding="utf-8") as output:
                result = subprocess.run(
                    [
                        str(bundle / "Graffitty.exe"),
                        "--quit-after",
                        "180",
                        "--script",
                        str(probe),
                        "--log-file",
                        str(profile / "runtime.log"),
                    ],
                    cwd=profile,
                    env=env,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    timeout=90,
                )
            text = log.read_text(encoding="utf-8", errors="replace")
            print(text)
            if failed(result.returncode, text):
                raise RuntimeError("Windows graphical startup reported errors")
            print("WINDOWS_GRAPHICAL_STARTUP_PASS")
        finally:
            descriptor = profile / "state/graffitty/server.json"
            if descriptor.exists():
                pid = json.loads(descriptor.read_text()).get("pid")
                if pid:
                    try:
                        process = psutil.Process(pid)
                        if (
                            process.create_time() >= started - 1
                            and Path(process.exe()).resolve()
                            == (bundle / "tools/gft.exe").resolve()
                        ):
                            process.terminate()
                            process.wait(timeout=10)
                    except psutil.NoSuchProcess:
                        pass


if __name__ == "__main__":
    main()
