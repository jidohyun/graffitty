"""Exercise the AppKit pinch bridge's touch and magnification lifecycles."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == "darwin", "AppKit requires macOS")
class TrackpadTests(unittest.TestCase):
    def test_native_pinch_and_pan(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-trackpad-") as directory:
            executable = Path(directory) / "trackpad-test"
            compiled = subprocess.run(
                [
                    "clang++",
                    "-std=c++17",
                    "-fobjc-arc",
                    str(ROOT / "tests/native/trackpad_test.mm"),
                    str(ROOT / "frontends/godot/extension/src/trackpad.mm"),
                    "-framework",
                    "AppKit",
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run(
                [str(executable)],
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS native Mac", result.stdout)


if __name__ == "__main__":
    unittest.main()
