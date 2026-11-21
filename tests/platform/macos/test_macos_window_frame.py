"""Verify grouped traffic-light hover with real AppKit button rendering."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == "darwin", "AppKit requires macOS")
class WindowFrameTests(unittest.TestCase):
    def test_native_traffic_light_hover(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-window-frame-") as directory:
            executable = Path(directory) / "window-frame-test"
            compiled = subprocess.run(
                [
                    "clang++",
                    "-std=c++17",
                    "-fobjc-arc",
                    str(ROOT / "tests/native/window_frame_macos_test.mm"),
                    str(ROOT / "frontends/godot/extension/src/window_frame_macos.mm"),
                    "-framework",
                    "AppKit",
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run(
                [str(executable)],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS native traffic lights", result.stdout)


if __name__ == "__main__":
    unittest.main()
