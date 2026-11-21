#!/usr/bin/env python3
"""Test: install.sh upgrades Graffitty on macOS without closing anything.

Steps:
1. Serve `--archive` to `packaging/install.sh` under one release tag in a
   temporary directory instead of GitHub.
2. Install the first release into a private Applications folder.
3. Open the installed app and start a program in its terminal.
4. Skip the identical archive, then install a republished archive under the same tag.

Passes when, after step 4:
- The program is the same process and still takes input.
- The server runs from the new app bundle.
- The window has reopened on the same session.

Run:

    python3 tests/platform/macos/macos_install_script_e2e.py --archive dist/graffitty-macos-arm64.tar.gz

Notes:
- A Graffitty window opens while the test runs.
- All state is in the temporary directory. Your own installation is not touched.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "packaging/linux")]
from test_installer import install_script  # noqa: E402
from test_terminal_holder import DRIVER, alive  # noqa: E402

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    arguments = parser.parse_args()
    archive = arguments.archive.resolve()
    # Keep this path short: Unix socket paths under it are limited to 104 bytes on macOS.
    root = Path(tempfile.mkdtemp(prefix="gfti", dir="/tmp")).resolve()
    applications = root / "Applications"
    applications.mkdir()
    app = applications / "Graffitty.app"
    cli = root / "bin/gft"
    env = {key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_", "TMUX", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    descriptor = root / "state/graffitty/server.json"
    driver = root / "driver.sh"
    driver.write_text(DRIVER)
    driver.chmod(0o755)
    (root / "config/graffitty").mkdir(parents=True)
    (root / "config/graffitty/server.toml").write_text(f'[terminal]\nshell = ["{driver}"]\nlogin_shell = false\n')
    env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor), HOLD_DIR=str(root))
    version = "v0.0.1"
    releases = root / "releases"
    releases.mkdir()
    local_archive = releases / archive.name
    shutil.copyfile(archive, local_archive)

    def publish():
        checksum = hashlib.sha256()
        with local_archive.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                checksum.update(block)
        (releases / f"{version}.txt").write_text(
            f"{checksum.hexdigest()}  graffitty-macos-arm64.tar.gz  {local_archive.name}\n")

    def install(skip=False):
        result = subprocess.run(
            ["sh"], input=install_script("install_macos"), text=True, capture_output=True, timeout=600,
            env=dict(env, GRAFFITTY_RELEASES=str(releases), GRAFFITTY_INSTALL_SKIP_IF_EXISTS=str(int(skip)), GRAFFITTY_VERSION=version,
                     GRAFFITTY_APP_DIR=str(applications), GRAFFITTY_BIN_DIR=str(root / "bin")))
        assert result.returncode == 0, f"install.sh {version}:\n{result.stdout}{result.stderr}"
        return result.stderr

    def gft(*args, pane=None):
        environment = dict(env)
        if pane is not None:
            for line in (root / f"{pane}.env").read_text().splitlines():
                key, _, value = line.partition("=")
                environment[key] = value
        result = subprocess.run([cli, *args], env=environment, capture_output=True, text=True, timeout=90)
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
        found = subprocess.run(["pgrep", "-f", str(app / "Contents/MacOS/GraffittyRuntime")],
                               capture_output=True, text=True).stdout.split()
        return {int(pid) for pid in found}

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
        publish()
        assert "No session server is running" in install()
        original = cli.stat().st_ino
        assert "No session server is running" in install()
        assert cli.stat().st_ino != original, "rerunning the command replaces even an identical release"
        assert (app / "Contents/MacOS/Graffitty").is_file() and cli.resolve().is_file(), "the app and its command are installed"
        assert not list(applications.glob(".graffitty-install.*")), "nothing is left beside the app"
        print("PASS install.sh installs the app and links its commands")

        subprocess.Popen([app / "Contents/MacOS/Graffitty"], env=env, cwd=root, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pane = wait(lambda: next(iter(programs()), None), "the terminal's program")
        wait(lambda: sessions()[0]["attached"], "the window to show its session")
        opened = wait(windows, "the app's window")
        server = json.loads(descriptor.read_text())["pid"]
        gft("terminal", "type", "--text", "before\n", pane=pane)
        wait(lambda: "got:before" in screen(pane), "the program's first reply")
        print("PASS the installed app runs a program in its terminal")

        parked_archive = local_archive.with_suffix(".away")
        local_archive.rename(parked_archive)
        assert "archive SHA-256 matches" in install(skip=True)
        assert json.loads(descriptor.read_text())["pid"] == server, "skipping restarted the server"
        parked_archive.rename(local_archive)
        # A second gzip member changes the published digest but preserves the signed app.
        with local_archive.open("ab") as stream:
            stream.write(gzip.compress(b""))
        publish()
        assert "1 terminal(s) kept" in install(skip=True)
        assert alive(pane), "the terminal's program survived"
        current = wait(lambda: json.loads(descriptor.read_text())["pid"] != server
                       and json.loads(descriptor.read_text())["pid"], "the upgraded server")
        command = subprocess.run(["ps", "-o", "command=", "-p", str(current)], capture_output=True, text=True).stdout
        assert command.startswith(str(app)), f"the server runs from the installed bundle: {command}"
        gft("terminal", "type", "--text", "after\n", pane=pane)
        wait(lambda: "got:after" in screen(pane), "the program's reply after the upgrade")
        assert "got:before" in screen(pane), "the screen kept its output from before the upgrade"
        assert (root / f"{pane}.input").read_text().split() == ["before", "after"], "input reached the same program"
        assert not list(applications.glob(".graffitty-install.*")), "the replaced bundle is gone"
        print("PASS the upgrade kept the program, its screen and its input")

        reopened = wait(lambda: windows() - opened, "the window to reopen")
        wait(lambda: not any(alive(pid) for pid in opened), "the replaced version's window to leave")
        wait(lambda: sessions()[0]["attached"], "the reopened window to show the session")
        time.sleep(3)
        assert all(alive(pid) for pid in reopened), "the reopened window stays"
        assert len(sessions()) == 1 and programs() == [pane], "the reopened window resumed, and opened nothing new"
        assert "archive SHA-256 matches" in install(skip=True), "the relaunched app held the installer lock"
        print("PASS the window reopened on the same session and released the install lock")
    finally:
        for pid in windows():
            os.kill(pid, signal.SIGKILL)
        for pid in subprocess.run(["pgrep", "-f", str(root)], capture_output=True, text=True).stdout.split():
            if int(pid) != os.getpid():
                os.kill(int(pid), signal.SIGKILL)
        for pid in programs():
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
        subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
