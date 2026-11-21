"""Godot can print script errors while returning success."""

import sys
import unittest
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tools",)]
from check_godot import failed


class GodotCheck(unittest.TestCase):
    def test_diagnostics_override_zero_exit(self):
        for text in [
            "SCRIPT ERROR: Parse Error: bad type",
            "ERROR: Failed to load script",
            "\x1b[31mERROR: invalid property\x1b[0m",
        ]:
            with self.subTest(text=text):
                self.assertTrue(failed(0, text))

    def test_exit_failure_and_clean_output(self):
        self.assertTrue(failed(1, ""))
        self.assertFalse(failed(0, "Godot Engine\nPASS\n"))


if __name__ == "__main__":
    unittest.main()
