"""Test: on Windows, terminal programs survive a server restart and an upgrade.

Setup:
- A private headless server runs from a staged installation (`<root>/app/tools`).
- The pane's shell is a driver script. It records its process id and pane
  capability, prints a marker, and echoes every input line.

Passes when the same program still runs, still shows its earlier output, and
still receives input after each of these:
1. A planned restart (`gft server restart`).
2. The installer steps: `gft internal update prepare`, replacing the locked
   executable, `gft internal update finish`.

Run:

    python tests/platform/windows/windows_terminal_holder.py [--cli dist/bin/gft.exe]

`tests/server/test_terminal_holder.py` covers the same on macOS and Linux.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
DRIVER = r'''import os, sys
hold, pid = os.environ["HOLD_DIR"], os.getpid()
with open(os.path.join(hold, f"{pid}.env"), "w") as out:
    out.writelines(f"{k}={v}\n" for k, v in os.environ.items() if k.startswith("GRAFFITTY_"))
print(f"before-marker-{pid}", flush=True)
with open(os.path.join(hold, "pids"), "a") as out:
    out.write(f"{pid}\n")
for line in sys.stdin:
    line = line.rstrip("\r\n")
    print(f"got:{line}", flush=True)
    with open(os.path.join(hold, f"{pid}.input"), "a") as out:
        out.write(line + "\n")
'''
HIDDEN = 0x08000000 | 0x00000200  # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP


def alive(pid):
    handle = ctypes.windll.kernel32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
    if not handle:
        return False
    running = ctypes.windll.kernel32.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT
    ctypes.windll.kernel32.CloseHandle(handle)
    return running


class Scenario:
    def __init__(self, cli):
        self.root = Path(tempfile.mkdtemp(prefix="gfth"))
        self.tools = self.root / "app/tools"
        self.tools.mkdir(parents=True)
        for name in ("gft.exe", "conpty.dll", "OpenConsole.exe"):
            if (cli.parent / name).is_file():
                shutil.copy2(cli.parent / name, self.tools / name)
        self.cli = self.tools / "gft.exe"
        (self.root / "driver.py").write_text(DRIVER)
        self.shell = self.root / "driver.cmd"
        self.shell.write_text(f'@"{sys.executable}" "%~dp0driver.py"\r\n')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GRAFFITTY_", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            self.env[f"XDG_{kind}_HOME"] = str(self.root / kind.lower())
        # Point APPDATA and LOCALAPPDATA at the test folder, so a real installation's state is never touched.
        for kind in ("APPDATA", "LOCALAPPDATA"):
            self.env[kind] = str(self.root / kind.lower())
            (self.root / kind.lower()).mkdir()
        self.descriptor = self.root / "state/graffitty/server.json"
        self.descriptor.parent.mkdir(parents=True)
        self.env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(self.descriptor), HOLD_DIR=str(self.root),
                        GRAFFITTY_HOLDER_GRACE_MS="300", PYTHONUTF8="1")

    def processes(self):
        """Running processes started from this test's folder, as {pid: command line}."""
        query = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*" + str(self.root)
                 + "*' -and $_.ProcessId -ne $PID } | ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }")
        output = subprocess.run(["powershell", "-NoProfile", "-Command", query],
                                capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
        return {int(pid): command for pid, _, command in
                (line.partition("\t") for line in output.splitlines() if "\t" in line)}

    def holders(self):
        return {pid for pid, command in self.processes().items() if "internal holder" in command}

    def diagnostics(self):
        logs = [self.root / "server.log", *self.descriptor.parent.glob("*.log")]
        return "\n".join(f"== {log.name}\n{log.read_text(errors='replace')[-3000:]}" for log in logs if log.exists())

    def wait(self, ready, what, seconds=40):
        deadline = time.monotonic() + seconds
        while True:
            try:
                value = ready()
            except (OSError, ValueError, subprocess.SubprocessError):
                value = None
            if value:
                return value
            if time.monotonic() >= deadline:
                raise AssertionError(f"Timed out waiting for {what}\n{self.diagnostics()}")
            time.sleep(.1)

    def server_pid(self):
        try:
            return json.loads(self.descriptor.read_text())["pid"]
        except (OSError, ValueError, KeyError):
            return None

    def start_server(self):
        log = (self.root / "server.log").open("ab")
        server = subprocess.Popen(
            [self.cli, "server", "--connection", self.descriptor, "--auth-file", self.root / "auth.json",
             "--shell", self.shell],
            env=self.env, cwd=self.root, stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=HIDDEN)
        self.wait(lambda: self.server_pid() == server.pid, "the server's descriptor")

    def gft(self, *args, pane=None, check=True):
        env = dict(self.env)
        if pane is not None:
            for line in (self.root / f"{pane}.env").read_text().splitlines():
                key, _, value = line.partition("=")
                env[key] = value
        result = subprocess.run([self.cli, *args], env=env, cwd=self.root, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=90, creationflags=HIDDEN)
        if check and (result.returncode or '"error"' in result.stdout):
            raise AssertionError(f"gft {' '.join(args)}: {result.stdout}{result.stderr}\n{self.diagnostics()}")
        return result.stdout

    def driver_pids(self):
        try:
            return [int(pid) for pid in (self.root / "pids").read_text().split()]
        except OSError:
            return []

    def new_pane(self, name):
        known = set(self.driver_pids())
        self.gft("session", "new", "-d", "-s", name)
        return self.wait(lambda: next(iter(set(self.driver_pids()) - known), None), f"the pane program in {name}")

    def screen(self, pane):
        return self.gft("terminal", "get-text", pane=pane)

    def assert_kept(self, pane, word):
        assert alive(pane), "the pane's program survived"
        self.wait(lambda: f"before-marker-{pane}" in self.screen(pane), "the earlier output on the adopted screen")
        self.gft("terminal", "type", "--text", word + "\n", pane=pane)
        self.wait(lambda: f"got:{word}" in self.screen(pane), f"the program's reply to {word}")
        assert (self.root / f"{pane}.input").read_text().split()[-1] == word, "input reached the same program"

    def stop(self):
        for pid in self.processes():
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        for pid in self.driver_pids():
            if alive(pid):
                subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        shutil.rmtree(self.root, ignore_errors=True)

    def run(self):
        self.start_server()
        pane = self.new_pane("one")
        holder = self.wait(lambda: next(iter(self.holders()), None), "the terminal holder")
        self.gft("terminal", "type", "--text", "before\n", pane=pane)
        self.wait(lambda: "got:before" in self.screen(pane), "the first reply")
        print("PASS a holder, not the server, runs the pane's program")

        first = self.server_pid()
        assert "1 terminal(s) kept" in self.gft("server", "restart")
        assert self.server_pid() != first and not alive(first), "a new server owns the session"
        assert "got:before" in self.screen(pane), "the saved screen keeps output from before the restart"
        self.assert_kept(pane, "after-restart")
        assert self.holders() == {holder}, "the same holder still runs the program"
        print("PASS a planned restart keeps the program, its screen and its input")

        second = self.server_pid()
        assert "1 terminal(s) kept" in self.gft("internal", "update", "prepare")
        assert not alive(second), "the server left"
        time.sleep(1.5)  # Well past the holder's grace.
        assert self.server_pid() is None, "nothing restarted the parked server"
        assert alive(pane) and alive(holder), "the holder kept the program"
        aside = [path.name for path in self.tools.iterdir() if ".old-" in path.name]
        assert any(name.startswith("gft.exe.old-") for name in aside), f"the holder's executable moved aside: {aside}"
        # Do what Setup does next: write a new executable at the path the locked one had.
        # `prepare` has just put a copy back under this name, and a virus scanner
        # may still hold a new executable for a moment.
        def replace():
            with self.cli.open("ab") as newer:
                newer.write(b"\0" * 16)
            return True
        self.wait(replace, "the executable's old path to accept a new file", seconds=10)
        print("PASS a parked server leaves its terminals held and its locked files replaceable")

        assert "1 terminal(s) kept" in self.gft("internal", "update", "finish")
        assert self.server_pid() not in (None, second)
        self.assert_kept(pane, "after-update")
        assert not self.descriptor.with_suffix(".update.json").exists(), "the parked record is spent"
        fresh = self.new_pane("two")
        self.wait(lambda: len(self.holders()) == 2, "the new build's holder for new terminals")
        assert holder in self.holders(), "the old holder keeps its terminal"
        print("PASS the installed version adopts the terminals; new ones go to its own holder")

        self.gft("session", "kill", "-t", "one")
        self.wait(lambda: not alive(pane), "the old session's program to end")
        self.wait(lambda: not alive(holder), "the drained old holder to exit")
        assert alive(fresh)
        self.gft("session", "kill", "-t", "two")
        self.wait(lambda: not self.processes(), "the server and its holders to exit")
        print("PASS a drained holder exits, and closing the last session leaves nothing behind")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=ROOT / "dist/bin/gft.exe")
    arguments = parser.parse_args()
    if os.name != "nt":
        raise SystemExit("Requires Windows; tests/server/test_terminal_holder.py covers macOS and Linux")
    scenario = Scenario(arguments.cli.resolve())
    try:
        scenario.run()
    finally:
        scenario.stop()


if __name__ == "__main__":
    main()
