"""Real MovieWriter/FFmpeg integration tests; require a graphical Godot build."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tools",)]
from av1 import probe_av1

GODOT = os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")


class Av1RecordingTests(unittest.TestCase):
    def record(self, output, encoder="ffmpeg"):
        return subprocess.run(
            [
                GODOT,
                "--path",
                str(ROOT / "frontends/godot/project"),
                "--write-movie",
                str(output),
                "--fixed-fps",
                "30",
                "--script",
                "tests/av1_movie_smoke.gd",
            ],
            env={
                **os.environ,
                "GRAFFITTY_MOVIE_PAUSED": "1",
                "GRAFFITTY_FFMPEG": encoder,
            },
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_direct_av1_and_capture_gating(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-av1-") as directory:
            output = Path(directory) / "capture.mp4"
            run = self.record(output)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("AV1_MOVIE_PASS frames=20", run.stdout)
            _, stream = probe_av1(output)
            self.assertEqual(int(stream["nb_read_frames"]), 20)
            self.assertEqual(stream["avg_frame_rate"], "30/1")
            self.assertFalse(list(Path(directory).glob("*.avi")))
            self.assertFalse(list(Path(directory).glob("*.partial.mp4")))

    def test_encoder_failure_does_not_publish_partial_video(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-av1-") as directory:
            output = Path(directory) / "capture.mp4"
            run = self.record(output, "/usr/bin/false")
            self.assertGreaterEqual(run.returncode, 0, "Encoder failure killed Godot with a signal")
            self.assertNotIn("AV1_MOVIE_PASS", run.stdout)
            self.assertIn("AV1 MovieWriter:", run.stdout + run.stderr)
            self.assertFalse(output.exists())
            self.assertFalse(list(Path(directory).glob("*.partial.mp4")))


if __name__ == "__main__":
    unittest.main()
