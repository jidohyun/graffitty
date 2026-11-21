"""Ctrl+C from the launching PTY must work even while Godot's main loop is stuck.

Run on macOS with the built extension: python3 tests/godot/test_launch_interrupt.py
"""

import os
import select
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GODOT = os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")


@unittest.skipUnless(sys.platform == "darwin", "macOS AppKit signal regression")
class LaunchInterruptTests(unittest.TestCase):
    def test_ctrl_c_terminates_blocked_main_loop(self):
        import pty

        with tempfile.TemporaryDirectory(prefix="graffitty-interrupt-") as tmp:
            script = Path(tmp) / "blocked.gd"
            script.write_text("""extends SceneTree
func _initialize() -> void:
    print("INTERRUPT_TEST_READY")
    while true:
        pass
""")
            pid, master = pty.fork()
            if pid == 0:
                os.chdir(ROOT)
                # Use AppKit, not --headless: they install different handlers.
                os.execv(GODOT, [GODOT, "--path", str(ROOT / "frontends/godot/project"), "--script", str(script)])
            reaped = False
            output = bytearray()
            try:
                deadline = time.monotonic() + 15
                while (
                    b"INTERRUPT_TEST_READY" not in output
                    and time.monotonic() < deadline
                ):
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            data = os.read(master, 65536)
                        except OSError:
                            break
                        if not data:
                            break
                        output.extend(data)
                self.assertIn(
                    b"INTERRUPT_TEST_READY", output, output.decode(errors="replace")
                )
                # Exercise the tty's ISIG/VINTR path, not just kill(SIGINT).
                os.write(master, b"\x03")
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        reaped = True
                        self.assertTrue(os.WIFSIGNALED(status), status)
                        self.assertEqual(os.WTERMSIG(status), signal.SIGINT)
                        return
                    time.sleep(0.02)
                self.fail("Ctrl+C did not terminate Godot within 3 seconds")
            finally:
                if not reaped:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
