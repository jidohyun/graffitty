"""Test: Windows Setup upgrades a running Graffitty without closing anything.

Steps:
1. Install `--setup` into `--directory`.
2. Open the installed app and start a program in its terminal.
3. Run the same Setup again, silently, as an upgrade.

Passes when, after step 3:
- The program is the same process and still takes input.
- The window has reopened on the same session.
- Setup did not hit a locked file.

Run:

    python tests/platform/windows/windows_installer_upgrade.py --setup <setup.exe> --directory <empty folder>

Notes:
- Run it on the logged-in desktop: the app opens a window.
- App state is in a temporary directory, but Setup registers what it
  installs. Use an installer built with its own AppId, or a machine without
  Graffitty. Never point `--directory` at an installation in use.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from windows_terminal_holder import DRIVER, HIDDEN, alive  # noqa: E402

SILENT = ["/SP-", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOCLOSEAPPLICATIONS", "/TASKS="]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--setup", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    if os.name != "nt":
        raise SystemExit("Requires Windows")
    directory = arguments.directory.resolve()
    if directory.exists() and any(directory.iterdir()):
        raise SystemExit(f"{directory} is not empty")
    root = Path(tempfile.mkdtemp(prefix="gftu"))
    env = {key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    env.update(HOLD_DIR=str(root), PYTHONUTF8="1")
    descriptor = root / "state/graffitty/server.json"
    (root / "driver.py").write_text(DRIVER)
    (root / "config/graffitty").mkdir(parents=True)
    shell = json.dumps([sys.executable, str(root / "driver.py")])
    (root / "config/graffitty/server.toml").write_text(f"[terminal]\nshell = {shell}\n")
    cli = directory / "tools/gft.exe"
    app = directory / "Graffitty.exe"

    def setup(log):
        result = subprocess.run([arguments.setup, *SILENT, f"/DIR={directory}", f"/LOG={root / log}"], env=env)
        text = (root / log).read_text(encoding="utf-8-sig", errors="replace")
        assert result.returncode == 0, f"Setup exited {result.returncode}\n{text[-3000:]}"
        return text

    def gft(*args, pane=None):
        environment = dict(env)
        if pane is not None:
            for line in (root / f"{pane}.env").read_text().splitlines():
                key, _, value = line.partition("=")
                environment[key] = value
        result = subprocess.run([cli, *args], env=environment, capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=90, creationflags=HIDDEN)
        assert result.returncode == 0 and '"error"' not in result.stdout, f"gft {' '.join(args)}: {result.stdout}{result.stderr}"
        return result.stdout

    def wait(ready, what, seconds=90):
        deadline = time.monotonic() + seconds
        while True:
            try:
                value = ready()
            except (OSError, ValueError, AssertionError, subprocess.SubprocessError):
                value = None
            if value:
                return value
            assert time.monotonic() < deadline, f"Timed out waiting for {what}"
            time.sleep(.2)

    def windows():
        """Process ids of the installed app's windows."""
        query = ("Get-CimInstance Win32_Process -Filter \"Name='GraffittyRuntime.exe'\" | Where-Object { $_.ExecutablePath -eq '"
                 + str(directory / "GraffittyRuntime.exe") + "' } | ForEach-Object { $_.ProcessId }")
        output = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True).stdout
        return {int(pid) for pid in output.split()}

    def sessions():
        return json.loads(gft("session", "list", "--json"))

    def programs():
        try:
            return [int(pid) for pid in (root / "pids").read_text().split()]
        except OSError:
            return []

    def screen(pane):
        return gft("terminal", "get-text", pane=pane)

    try:
        setup("install.log")
        assert cli.is_file() and app.is_file(), "Setup installed the app and its CLI"
        print("PASS Setup installs into an empty folder")

        subprocess.Popen([app], env=env, cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        pane = wait(lambda: next(iter(programs()), None), "the terminal's program")
        wait(lambda: sessions()[0]["attached"], "the window to show its session")
        opened = wait(windows, "the app's window")
        server = json.loads(descriptor.read_text())["pid"]
        gft("terminal", "type", "--text", "before\n", pane=pane)
        wait(lambda: "got:before" in screen(pane), "the program's first reply")
        print("PASS the installed app runs a program in its terminal")

        log = setup("upgrade.log")
        locked = [line for line in log.splitlines() if "failed; code 5" in line or "failed; code 32" in line]
        assert not locked, f"Setup met locked files: {locked[:3]}"
        assert alive(pane), "the terminal's program survived the upgrade"
        wait(lambda: json.loads(descriptor.read_text())["pid"] != server, "the installed version's server")
        assert not alive(server), "the replaced server left"
        gft("terminal", "type", "--text", "after\n", pane=pane)
        wait(lambda: "got:after" in screen(pane), "the program's reply after the upgrade")
        assert "got:before" in screen(pane), "the screen kept its output from before the upgrade"
        assert (root / f"{pane}.input").read_text().split() == ["before", "after"], "input reached the same program"
        print("PASS the upgrade kept the program, its screen and its input")

        reopened = wait(lambda: windows() - opened, "the window to reopen")
        assert not any(alive(pid) for pid in opened), "the replaced version's window left"
        wait(lambda: sessions()[0]["attached"], "the reopened window to show the session")
        assert len(sessions()) == 1 and programs() == [pane], "the reopened window resumed, and opened nothing new"
        print(f"PASS the window reopened on the same session ({len(reopened)} window)")
    finally:
        for pid in windows():
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        query = ("Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '" + str(directory)
                 + "\\*' -or $_.CommandLine -like '*" + str(root) + "*' } | ForEach-Object { $_.ProcessId }")
        leftover = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True).stdout
        for pid in leftover.split():
            subprocess.run(["taskkill", "/F", "/PID", pid], capture_output=True)
        uninstaller = directory / "unins000.exe"
        if uninstaller.is_file():
            subprocess.run([uninstaller, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"], env=env)
        for log in ("install.log", "upgrade.log"):
            if (root / log).is_file():
                shutil.copy(root / log, Path(tempfile.gettempdir()) / f"graffitty-{log}")
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
