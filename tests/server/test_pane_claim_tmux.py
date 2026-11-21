"""Check that gft inside tmux finds the pane displaying it via OSC 4723.

Each scenario uses a private headless server and driver-script shells.

1. Start tmux in the first pane. The server inherits that pane's variables.
2. Attach from another pane and run gft in a new tmux window.
3. Check that gft resolves the pane displaying the command.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/debug/gft"))

DRIVER = r"""#!/bin/sh
T="tmux -L $CLAIM_TMUX -f $CLAIM_DIR/tmux.conf"
probe='printf "inherited=%s\n" "$GRAFFITTY_PANE" > "$CLAIM_DIR/$0.out"; "$GFT" pane pid >> "$CLAIM_DIR/$0.out" 2>&1; echo done >> "$CLAIM_DIR/$0.out"'
if [ "$CLAIM_MODE" = closed ] && [ ! -f "$CLAIM_DIR/keeper" ]; then touch "$CLAIM_DIR/keeper"; exec sleep 600; fi
if $T has-session -t s 2>/dev/null; then
  $T attach -t s \; new-window "sh -c '$probe; sleep 600' second"
else
  if [ "$CLAIM_MODE" = shared ]; then
    $T new-session -s s "sh -c '$probe; sleep 600' first"
  else
    $T new-session -s s "sh -c '$probe; $T detach-client; sleep 600' first"
  fi
  touch "$CLAIM_DIR/first.detached"
  [ "$CLAIM_MODE" = closed ] && exit 0
fi
exec sleep 600
"""


@unittest.skipUnless(os.name == "posix" and shutil.which("tmux") and CLI.exists(),
                     "Requires POSIX, tmux and a built gft")
class PaneClaimTmuxTests(unittest.TestCase):
    def scenario(self, mode, passthrough="all"):
        # Short root: the server and terminal holder keep Unix sockets beneath it.
        with tempfile.TemporaryDirectory(prefix="gftc", dir="/tmp") as directory:
            root = Path(directory)
            tmux = f"gftclaim{os.getpid()}{mode}"
            driver = root / "driver.sh"
            driver.write_text(DRIVER)
            driver.chmod(0o755)
            (root / "tmux.conf").write_text(
                f"set -g allow-passthrough {passthrough}\nset -g default-shell /bin/sh\n")
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GRAFFITTY_", "TMUX", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            # Panes never inherit GRAFFITTY_SERVER_DESCRIPTOR; keep the default
            # location so the closed-pane fallback finds the local capability.
            descriptor = root / "state/graffitty/server.json"
            descriptor.parent.mkdir(parents=True, mode=0o700)
            env.update(GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor), SHELL=str(driver), GFT=str(CLI),
                       CLAIM_DIR=str(root), CLAIM_MODE=mode, CLAIM_TMUX=tmux)
            log = (root / "server.log").open("wb")
            server = subprocess.Popen([CLI, "server", "--connection", descriptor,
                                       "--auth-file", root / "auth.json", "--shell", driver],
                                      env=env, cwd=root, stdout=log, stderr=log)

            def wait(path, seconds=20):
                deadline = time.monotonic() + seconds
                while not (path.exists() and (path.suffix != ".out" or "done" in path.read_text())):
                    self.assertIsNone(server.poll(), (root / "server.log").read_text())
                    self.assertLess(time.monotonic(), deadline, f"Timed out waiting for {path.name}")
                    time.sleep(.05)
                return path.read_text()

            def new(name):
                subprocess.run([CLI, "session", "new", "-d", "-s", name], env=env, cwd=root,
                               check=True, capture_output=True, timeout=20)
            try:
                wait(descriptor)
                if mode == "closed":
                    new("keep")
                    wait(root / "keeper")
                new("one")
                first = wait(root / "first.out")
                if mode != "shared":
                    wait(root / "first.detached")
                new("two")
                return first, wait(root / "second.out")
            finally:
                subprocess.run(["tmux", "-L", tmux, "kill-server"], capture_output=True)
                server.terminate()
                server.wait(timeout=10)
                log.close()

    @staticmethod
    def pane(output):
        lines = output.splitlines()
        inherited = lines[0].removeprefix("inherited=")
        reply = json.loads(lines[1])
        return inherited, reply.get("result", {}).get("terminals", [{}])[0].get("pane"), reply.get("error")

    def test_attaching_from_another_pane_claims_the_displaying_pane(self):
        first, second = self.scenario("detached")
        self.assertEqual(self.pane(first)[:2], ("%1", "%1"))
        inherited, claimed, _ = self.pane(second)
        self.assertEqual(inherited, "%1", "tmux keeps the first pane's variables")
        self.assertEqual(claimed, "%2")

    def test_closed_origin_pane_falls_back_to_the_local_capability(self):
        _, second = self.scenario("closed")
        inherited, claimed, _ = self.pane(second)
        self.assertEqual((inherited, claimed), ("%2", "%3"))

    def test_session_attached_from_two_panes_is_ambiguous(self):
        _, second = self.scenario("shared")
        error = self.pane(second)[2]
        self.assertIn("several Graffitty panes", error["message"])

    def test_passthrough_off_fails_with_a_configuration_hint(self):
        _, second = self.scenario("detached", passthrough="off")
        error = self.pane(second)[2]
        self.assertIn("allow-passthrough all", error["message"])


if __name__ == "__main__":
    unittest.main()
