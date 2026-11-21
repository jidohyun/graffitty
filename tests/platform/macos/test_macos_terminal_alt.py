"""Native Option routing without activating a desktop window."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == "darwin", "AppKit requires macOS")
class TerminalAltTests(unittest.TestCase):
    def test_native_alt_routing(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-alt-") as directory:
            binary = Path(directory) / "test"
            result = subprocess.run([
                "clang++", "-std=c++17", "-fobjc-arc",
                str(ROOT / "tests/native/terminal_alt_macos_test.mm"),
                str(ROOT / "frontends/godot/extension/src/ime_shim.mm"),
                "-framework", "AppKit", "-o", str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS native terminal Alt and IME", result.stdout)
