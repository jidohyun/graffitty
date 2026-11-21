"""Real encrypted WebSockets, owner PTY and two Godot terminal replicas."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SERVER = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/debug/gft"))


@unittest.skipUnless(shutil.which("godot") and SERVER.exists(), "Build native binaries first")
class RemoteResumeTests(unittest.TestCase):
    def test_silent_connection_loss_recovers_after_backgrounding(self):
        result = subprocess.run(
            ["godot", "--headless", "--path", ROOT / "frontends/godot/project",
             "--script", "res://tests/remote_resume_smoke.gd"],
            capture_output=True, text=True, timeout=70,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("REMOTE_RESUME_PASS", output)
        # The fixture records runtime engine errors before quitting. Godot also
        # reports its retained ChromiumVideoSupport static script at shutdown.
        self.assertNotIn("SCRIPT ERROR:", output)
        print(result.stdout, flush=True)


if __name__ == "__main__":
    unittest.main()
