"""Tests: terminal programs keep running when the session server does not.

Setup for each test:
- A private headless server.
- The pane's shell is a driver script. It records its pid and pane
  capability, prints a marker, and echoes every input line.

Each test restarts the server, crashes it, or replaces it with another build.
Afterwards the same program must:
- still run,
- still show its earlier output,
- still receive input through the capability it started with.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tools",)]
import dev_server

CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))

DRIVER = r"""#!/bin/sh
env | grep -E '^(GRAFFITTY_|HANDOVER_|CLAUDE_CODE_SESSION_ID=)' > "$HOLD_DIR/$$.env"
echo "before-marker-$$"
echo $$ >> "$HOLD_DIR/pids"
while IFS= read -r line; do
  echo "got:$line"
  echo "$line" >> "$HOLD_DIR/$$.input"
done
"""


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def parent(pid):
    return int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                              capture_output=True, text=True, check=True).stdout)


@unittest.skipUnless(os.name == "posix" and CLI.exists(), "Requires macOS/Linux and a built gft")
class TerminalHolderTests(unittest.TestCase):
    def setUp(self):
        # Keep this path short: Unix socket paths under it are limited to 104 bytes on macOS.
        # Set GRAFFITTY_TEST_TMPDIR to another short path if /tmp is too small.
        self.root = Path(tempfile.mkdtemp(prefix="gfth", dir=os.environ.get("GRAFFITTY_TEST_TMPDIR", "/tmp")))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.cli = CLI
        driver = self.root / "driver.sh"
        driver.write_text(DRIVER)
        driver.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GRAFFITTY_", "TMUX", "CODEX_"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            self.env[f"XDG_{kind}_HOME"] = str(self.root / kind.lower())
        self.descriptor = self.root / "state/graffitty/server.json"
        self.descriptor.parent.mkdir(parents=True, mode=0o700)
        self.env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(self.descriptor), SHELL=str(driver),
                        HOLD_DIR=str(self.root), GRAFFITTY_HOLDER_GRACE_MS="300")
        self.addCleanup(self.stop_everything)

    def start_server(self):
        self.log = (self.root / "server.log").open("ab")
        self.server = subprocess.Popen(
            [self.cli, "server", "--connection", self.descriptor, "--auth-file", self.root / "auth.json",
             "--shell", self.env["SHELL"]],
            env=self.env, cwd=self.root, stdout=self.log, stderr=self.log)
        self.wait(lambda: self.server_pid() == self.server.pid, "server descriptor")

    def stop_everything(self):
        pid = self.server_pid()
        for candidate in {pid, getattr(self, "server", None) and self.server.pid} - {None}:
            if alive(candidate):
                os.kill(candidate, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.processes():
            time.sleep(.1)
        for leftover in self.processes():
            os.kill(leftover, signal.SIGKILL)
        if getattr(self, "server", None):
            self.server.wait(timeout=10)
        if getattr(self, "log", None):
            self.log.close()

    def processes(self):
        """Running servers, holders and drivers started from this test's folder."""
        found = subprocess.run(["pgrep", "-f", str(self.root)], capture_output=True, text=True).stdout.split()
        found += [str(pid) for pid in self.driver_pids() if alive(pid)]
        return {int(pid) for pid in found} - {os.getpid()}

    def diagnostics(self):
        logs = [self.root / "server.log", *self.descriptor.parent.glob("*.log")]
        return "\n".join(f"== {log.name}\n{log.read_text(errors='replace')[-4000:]}" for log in logs if log.exists())

    def wait(self, ready, what, seconds=30):
        deadline = time.monotonic() + seconds
        while True:
            try:
                value = ready()
            except (OSError, ValueError, subprocess.SubprocessError):
                value = None
            if value:
                return value
            self.assertLess(time.monotonic(), deadline, f"Timed out waiting for {what}\n{self.diagnostics()}")
            time.sleep(.05)

    def server_pid(self):
        try:
            return json.loads(self.descriptor.read_text())["pid"]
        except (OSError, ValueError, KeyError):
            return None

    def gft(self, *args, pane=None, check=True):
        env = dict(self.env)
        if pane is not None:
            for line in (self.root / f"{pane}.env").read_text().splitlines():
                key, _, value = line.partition("=")
                env[key] = value
        result = subprocess.run([self.cli, *args], env=env, cwd=self.root,
                                capture_output=True, text=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, f"gft {' '.join(args)}: {result.stdout}{result.stderr}")
            self.assertNotIn('"error"', result.stdout, f"gft {' '.join(args)}")
        return result.stdout

    def driver_pids(self):
        try:
            return [int(pid) for pid in (self.root / "pids").read_text().split()]
        except OSError:
            return []

    def new_pane(self, name):
        known = set(self.driver_pids())
        self.gft("session", "new", "-d", "-s", name)
        return self.wait(lambda: next(iter(set(self.driver_pids()) - known), None), f"pane shell in {name}")

    def screen(self, pane):
        return self.gft("terminal", "get-text", pane=pane)

    def assert_kept(self, pane, holder, rounds):
        """Checks the pane's program: same process, same holder, output kept, input works."""
        self.assertTrue(alive(pane), "the pane's program survived")
        self.assertEqual(parent(pane), holder, "the same holder still owns the program")
        self.wait(lambda: f"before-marker-{pane}" in self.screen(pane), "the earlier output on the adopted screen")
        word = f"after-{rounds}"
        self.gft("terminal", "type", "--text", word + "\n", pane=pane)
        self.wait(lambda: f"got:{word}" in self.screen(pane), "the program's reply on screen")
        self.assertEqual((self.root / f"{pane}.input").read_text().split()[-1], word,
                         "input reached the same program")
        sessions = self.gft("session", "list", "--json")
        self.assertIn("one", sessions)

    def started(self):
        self.start_server()
        pane = self.new_pane("one")
        holder = parent(pane)
        self.assertNotEqual(holder, self.server_pid(), "a holder, not the server, is the program's parent")
        self.gft("terminal", "type", "--text", "before\n", pane=pane)
        self.wait(lambda: "got:before" in self.screen(pane), "the first reply")
        return pane, holder

    def test_dev_restart_preserves_program_and_screen(self):
        pane, holder = self.started()
        first = self.server_pid()
        with (patch.object(dev_server.sys.stdin, "isatty", return_value=True),
              patch("builtins.input", return_value="2")):
            dev_server.restart_if_requested(self.cli, self.descriptor, self.env)
        self.assertNotEqual(first, self.server_pid())
        self.assert_kept(pane, holder, 1)

    def test_dev_reset_ends_old_program_and_starts_new_build_holder(self):
        installed = self.root / "bin/gft"
        installed.parent.mkdir()
        shutil.copy2(CLI, installed)
        self.cli = installed
        pane, holder = self.started()
        staged = installed.with_name("gft.new")
        shutil.copy(CLI, staged)
        os.replace(staged, installed)
        # Give the launcher an invalid capability. It must not use a pane's capability by accident.
        env = dict(self.env, GRAFFITTY_SOCKET="invalid-pane", GRAFFITTY_TOKEN="invalid-token")
        with (patch.object(dev_server.sys.stdin, "isatty", return_value=True),
              patch("builtins.input", side_effect=["3", "RESTART"])):
            dev_server.restart_if_requested(self.cli, self.descriptor, env)
        self.wait(lambda: not alive(pane), "old program ends")
        self.wait(lambda: not alive(holder), "old build holder exits")
        self.wait(lambda: len(self.driver_pids()) >= 2, "fresh terminal starts")
        fresh = self.driver_pids()[-1]
        self.assertNotEqual(fresh, pane)
        self.assertTrue(alive(fresh))
        self.assertNotEqual(parent(fresh), holder)
        sessions = json.loads(self.gft("session", "list", "--json"))
        self.assertEqual(len(sessions), 1)
        self.assertNotEqual(sessions[0].get("name"), "one")

    def test_planned_restart_keeps_programs_and_screens(self):
        pane, holder = self.started()
        first = self.server_pid()
        self.assertIn("1 terminal(s) kept", self.gft("server", "restart"))
        self.assertNotEqual(self.server_pid(), first, "a new server owns the session")
        self.assertIsNotNone(self.server.wait(timeout=20), "the previous server exited")
        self.assertIn("got:before", self.screen(pane), "the saved screen keeps output from before the restart")
        self.assert_kept(pane, holder, 1)
        # Restart twice: a server that adopted terminals must be able to hand them over again.
        self.gft("server", "restart")
        self.assert_kept(pane, holder, 2)

    def test_restart_keeps_the_servers_environment_not_the_callers(self):
        # An agent (or a pane's shell) that restarts the server must not become
        # every later terminal's environment: its session, socket and account.
        self.env["HANDOVER_MARK"] = "launcher"
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)  # The test may itself run inside an agent.
        for terminals in (False, True):
            if terminals:
                self.started()
            else:
                self.start_server()
            first = self.server_pid()
            caller = dict(self.env, HANDOVER_MARK="agent", CLAUDE_CODE_SESSION_ID="leaked-session")
            result = subprocess.run([self.cli, "server", "restart"], env=caller, cwd=self.root,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.wait(lambda: self.server_pid() not in (None, first), "the restarted server")
            pane = self.new_pane(f"after-{int(terminals)}")
            recorded = dict(line.partition("=")[::2] for line in (self.root / f"{pane}.env").read_text().splitlines())
            self.assertEqual(recorded.get("HANDOVER_MARK"), "launcher", "the new server keeps its predecessor's environment")
            self.assertNotIn("CLAUDE_CODE_SESSION_ID", recorded, "the restarting agent's session does not leak")
            self.assertFalse(self.descriptor.with_name("server.environment.json").exists(), "the handover is consumed")
            self.stop_everything()

    def test_filetree_association_survives_repeated_restart(self):
        runtime = ROOT / "dist/filetree"
        if not (runtime / "manifest.json").exists():
            self.skipTest("Requires the bundled filetree runtime")
        pane, holder = self.started()
        self.gft("rpc", "filetree.toggle", "--params", "{}", pane=pane)
        owner_path = self.descriptor.with_name("server.owner.json")

        def tree_state():
            return json.loads(owner_path.read_text())["filetrees"]["active"]

        trees = self.wait(lambda: tree_state(), "the persisted filetree association")
        self.assertEqual(len(trees), 1)
        tree_id, tree = next(iter(trees.items()))
        state = json.loads(owner_path.read_text())
        owner_id = next(s["id"] for s in state["sessions"] if s["id"] != int(tree_id))
        self.assertEqual(tree["owner"], owner_id)
        manifest = json.loads((runtime / "manifest.json").read_text())
        nvim = runtime / manifest["nvim"]

        def tree_pid():
            result = subprocess.run([nvim, "--clean", "--headless", "--server", tree["address"],
                                     "--remote-expr", "getpid()"], capture_output=True, text=True, timeout=5)
            return int(result.stdout.strip()) if result.returncode == 0 else None

        pid = self.wait(tree_pid, "filetree RPC readiness", seconds=90)
        for iteration in range(2):
            self.assertIn("2 terminal(s) kept", self.gft("server", "restart"))
            self.assert_kept(pane, holder, iteration)
            self.assertEqual(tree_state(), trees, "the association and original RPC address survive")
            self.assertEqual(self.wait(tree_pid, "adopted filetree RPC"), pid, "the same Neovim is connected")
        # Crash recovery reads the state the server saved before it replied to each RPC.
        first = self.server_pid()
        os.kill(first, signal.SIGKILL)
        self.wait(lambda: self.server_pid() not in (None, first) and alive(self.server_pid()),
                  "the holder to restart the filetree owner")
        self.assertTrue(alive(pane))
        self.assertEqual(parent(pane), holder)
        self.gft("terminal", "type", "--text", "after-crash\n", pane=pane)
        self.wait(lambda: "got:after-crash" in self.screen(pane), "input after crash recovery")
        self.assertEqual(tree_state(), trees)
        self.assertEqual(self.wait(tree_pid, "filetree RPC after crash"), pid)
        # Toggle must close the filetree the server adopted. It must not open a second one.
        self.gft("rpc", "filetree.toggle", "--params", "{}", pane=pane)
        self.wait(lambda: not alive(pid), "the connected filetree to close")
        self.assertEqual(tree_state(), {})
        self.assertEqual(len(json.loads(owner_path.read_text())["sessions"]), 1)

    def test_crashed_server_is_restarted_by_the_holder(self):
        pane, holder = self.started()
        # No waiting here on purpose: once the caller has its reply, the new
        # session and its input must already be saved.
        state = json.loads(self.descriptor.with_name("server.owner.json").read_text())
        self.assertEqual(len(state["sessions"]), 1)
        first = self.server_pid()
        os.kill(first, signal.SIGKILL)
        self.server.wait(timeout=10)
        self.wait(lambda: (self.server_pid() not in (None, first)
                           and "one" in self.gft("session", "list", check=False)), "the holder to restart the server")
        self.assertIn("got:before", self.screen(pane), "the holder's tail rebuilds the screen")
        self.assert_kept(pane, holder, 1)

    def test_updated_build_adopts_old_terminals_and_drains_the_old_holder(self):
        # A new binary at the same path counts as a new build: the server
        # identifies its build by the executable file.
        installed = self.root / "bin/gft"
        installed.parent.mkdir()
        shutil.copy2(CLI, installed)
        self.cli = installed
        pane, holder = self.started()
        staged = installed.with_name("gft.new")
        shutil.copy(CLI, staged)
        os.replace(staged, installed)
        self.gft("server", "restart")
        self.assert_kept(pane, holder, 1)
        newer = self.new_pane("two")
        self.assertNotEqual(parent(newer), holder, "new terminals go to the new build's holder")
        self.assertTrue(alive(holder), "the old holder keeps its terminal")
        self.gft("session", "kill", "-t", "one")
        self.wait(lambda: not alive(pane), "the old session's program to end")
        self.wait(lambda: not alive(holder), "the drained old holder to exit")
        self.assertTrue(alive(newer))

    def test_versioned_installation_restarts_as_the_version_an_upgrade_made_current(self):
        # The Linux layout: one directory per version, and a `current` link to the one in use.
        installs = self.root / "installs"
        for version in ("0.1.0", "0.2.0"):
            (installs / version / "tools").mkdir(parents=True)
            shutil.copy(CLI, installs / version / "tools/gft")
        (installs / "current").symlink_to("0.1.0")
        self.cli = installs / "0.1.0/tools/gft"
        pane, holder = self.started()
        environment = (self.root / f"{pane}.env").read_text()
        self.assertIn(f"GRAFFITTY_BIN={installs}/current/tools/gft", environment,
                      "a terminal's gft outlives the version that started it")
        # Do what install.sh does: switch the link, then run the new version's finish step.
        (installs / "current.new").symlink_to("0.2.0")
        os.replace(installs / "current.new", installs / "current")
        self.cli = installs / "current/tools/gft"
        self.assertIn("1 terminal(s) kept", self.gft("internal", "update", "finish"))
        self.assert_kept(pane, holder, 1)
        newer = self.new_pane("two")
        command = subprocess.run(["ps", "-o", "command=", "-p", str(parent(newer))],
                                 capture_output=True, text=True, check=True).stdout
        self.assertNotEqual(parent(newer), holder, "new terminals go to the new version's holder")
        self.assertIn(str((installs / "0.2.0").resolve()), str(Path(command.split()[0]).resolve()),
                      "the restarted server runs the version the upgrade made current")

    def test_install_script_upgrades_a_running_graffitty_twice(self):
        """Runs packaging/install.sh from start to end. Releases come from local fixtures."""
        sys.path.insert(0, str(ROOT / "packaging/linux"))
        from test_installer import install_script, write_release
        releases = self.root / "releases"
        installs = self.root / "data/graffitty/installs"

        def install(version):
            if not (releases / version).exists():
                write_release(releases, version, CLI)
            env = dict(self.env, GRAFFITTY_RELEASES=str(releases), GRAFFITTY_VERSION=version, GRAFFITTY_NO_DESKTOP="1",
                       GRAFFITTY_BIN_DIR=str(self.root / "bin"))
            result = subprocess.run(["sh"], input=install_script(), text=True, capture_output=True, env=env,
                                    timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.readlink(installs / "current"), version[1:])
            return result.stderr

        self.assertIn("No session server is running", install("v0.1.0"))
        self.cli = self.root / "bin/gft"
        pane, holder = self.started()
        self.assertIn("1 terminal(s) kept", install("v0.2.0"))
        self.assert_kept(pane, holder, 1)
        server = Path(subprocess.run(["ps", "-o", "command=", "-p", str(self.server_pid())],
                                     capture_output=True, text=True, check=True).stdout.split()[0])
        self.assertEqual(server.resolve(), (installs / "0.2.0/tools/gft").resolve(),
                         "the server restarted as the installed version")
        # This upgrade deletes the version directory the first terminal's holder runs from.
        self.assertIn("1 terminal(s) kept", install("v0.3.0"))
        self.assertFalse((installs / "0.1.0").exists(), "the installer kept only the two newest versions")
        self.assert_kept(pane, holder, 2)
        newer = self.new_pane("two")
        self.assertNotEqual(parent(newer), holder, "new terminals go to the installed version's holder")
        newer_holder = parent(newer)
        self.assertIn("2 terminal(s) kept", install("v0.3.0"))
        self.assert_kept(pane, holder, 3)
        self.assert_kept(newer, newer_holder, 3)

    def test_parked_server_leaves_terminals_held_until_the_installation_finishes(self):
        pane, holder = self.started()
        first = self.server_pid()
        self.assertIn("1 terminal(s) kept", self.gft("internal", "update", "prepare"))
        self.assertIsNotNone(self.server.wait(timeout=20), "the server left")
        # Wait longer than the holder's restart delay. It must not start a server during an upgrade.
        time.sleep(1.5)
        self.assertIsNone(self.server_pid(), "nothing restarted the parked server")
        self.assertTrue(alive(pane) and alive(holder), "the holder kept the program")
        self.assertIn("1 terminal(s) kept", self.gft("internal", "update", "finish"))
        self.assertNotEqual(self.server_pid(), first)
        self.assert_kept(pane, holder, 1)
        self.assertFalse(self.descriptor.with_suffix(".update.json").exists(), "the parked record is spent")
        # Finishing a second time must do nothing: nothing is parked and the build is the same.
        resumed = self.server_pid()
        self.assertIn("already runs this version", self.gft("internal", "update", "finish"))
        self.assertEqual(self.server_pid(), resumed)
        self.assert_kept(pane, holder, 2)

    def test_update_steps_without_a_server_do_nothing(self):
        self.assertIn("No session server is running", self.gft("internal", "update", "prepare"))
        self.assertIn("No session server is running", self.gft("internal", "update", "finish"))
        self.assertEqual(self.processes(), set())

    def test_creation_and_close_commit_before_reply(self):
        self.start_server()
        owner = self.descriptor.with_name("server.owner.json")
        self.gft("session", "new", "-d", "-s", "one")
        state = json.loads(owner.read_text())
        self.assertEqual(len(state["sessions"]), 1)
        # Keep a second session open. The server exits when its last session
        # closes, and deletes this file when it exits.
        self.gft("session", "new", "-d", "-s", "two")
        kept = {session["id"] for session in json.loads(owner.read_text())["sessions"]} - {state["sessions"][0]["id"]}
        self.assertEqual(len(kept), 1)
        self.gft("session", "kill", "-t", "one")
        self.assertEqual({session["id"] for session in json.loads(owner.read_text())["sessions"]}, kept)
        self.gft("session", "kill", "-t", "two")
        self.wait(lambda: not owner.exists(), "the last session's server to clear its state")

    def test_creation_reports_persistence_failure(self):
        self.start_server()
        owner = self.descriptor.with_name("server.owner.json")
        owner.unlink()
        owner.mkdir()  # Atomic rename cannot replace a directory with a file.
        result = subprocess.run([self.cli, "session", "new", "-d", "-s", "one"],
                                env=self.env, cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, "a non-recoverable pane must not be acknowledged")
        self.assertTrue(owner.is_dir())
        owner.rmdir()

    def test_server_shutdown_ends_programs_and_holders(self):
        pane, holder = self.started()
        self.server.send_signal(signal.SIGTERM)
        self.server.wait(timeout=20)
        self.wait(lambda: not alive(pane) and not alive(holder), "the program and holder to exit")


if __name__ == "__main__":
    unittest.main()
