"""Owner-to-renderer checks. Enable GPU checks with GRAFFITTY_TEST_GPU_IMAGES=1.

Build/stage the Godot extension and build gft before running.
"""
import base64
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/server",)]
from test_terminal_scene import ROOT, SERVER, Owner, png
GODOT = os.environ.get("GRAFFITTY_TEST_GODOT") or shutil.which("godot")


@unittest.skipUnless(GODOT and SERVER.exists(), "Build native binaries first")
class TerminalSceneGodotTests(unittest.TestCase):
    def test_particle_count_per_key_and_duplicate_ime_notification(self):
        result = subprocess.run(["godot", "--headless", "--path", ROOT / "frontends/godot/project",
            "--script", "res://tests/typing_particle_count_smoke.gd"],
            capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("ERROR:", output)
        self.assertIn("TYPING_PARTICLE_COUNT_PASS", output)

    def test_typing_and_ime_follow_hidden_cursor(self):
        result = subprocess.run([GODOT, "--headless", "--path", ROOT / "frontends/godot/project",
            "--script", "res://tests/terminal_hidden_cursor_typing_smoke.gd"],
            capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("HIDDEN_CURSOR_TYPING_PASS", output)

    def test_camera_redraw_without_terminal_events(self):
        result = subprocess.run([GODOT, "--headless", "--path", ROOT / "frontends/godot/project",
            "--script", "res://tests/image_plane_redraw_smoke.gd"],
            capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("FAIL ", output)
        self.assertNotIn("ERROR:", output)

    def run_scene(self, graphical=False, motion=False, script=None, raw_pixels=False):
        with Owner() as owner:
            image = owner.path / "image.png"
            image.write_bytes(png(1024))
            (owner.path / "image.vt").write_bytes(b"\x1b[3;1H\x1b_Ga=T,t=f,f=100,i=91,p=1,c=20,r=10,C=1,q=2;"
                + base64.b64encode(os.fsencode(image)) + b"\x1b\\\x1b[20;1H@@IMAGE_DONE@@")
            (owner.path / "erase.vt").write_bytes(b"\x1b_Ga=d,d=a,q=2;\x1b\\\x1b[21;1H@@ERASE_DONE@@")
            (owner.path / "reuse.vt").write_bytes(b"\x1b[3;1H\x1b_Ga=p,i=91,p=2,c=20,r=10,C=1,q=2;\x1b\\\x1b[22;1H@@REUSE_DONE@@")
            (owner.path / "erase-line.vt").write_bytes(b"\x1b[24;1H\x1b[2KANCHOR")
            env = dict(os.environ, GRAFFITTY_SCENE_FIXTURE=str(owner.path), GRAFFITTY_TEST_SERVER=str(SERVER),
                       GRAFFITTY_SERVER=str(SERVER), GRAFFITTY_SERVER_DESCRIPTOR=str(owner.descriptor),
                       XDG_CONFIG_HOME=str(owner.path / "config"))
            env["GRAFFITTY_TEST_RAW_IMAGE_PIXELS"] = "1" if raw_pixels else "0"
            args = (["--rendering-driver", "d3d12" if os.name == "nt" else "metal" if sys.platform == "darwin" else "vulkan"]
                    if graphical else ["--headless"])
            script = script or ("terminal_scene_motion_smoke.gd" if motion else "terminal_scene_smoke.gd")
            result = subprocess.run([GODOT, *args, "--path", ROOT / "frontends/godot/project",
                "--script", "res://tests/" + script], env=env, capture_output=True, text=True, timeout=80)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("FAIL ", output)
            self.assertNotIn("SCRIPT ERROR", output)
            print(result.stdout, flush=True)

    def test_headless_portable_assets_and_atomic_state(self):
        self.run_scene()

    def test_copy_mode_freezes_scene_replica(self):
        self.run_scene(script="terminal_scene_freeze_smoke.gd")

    @unittest.skipUnless(os.name == "nt" and os.environ.get("GRAFFITTY_TEST_GPU_IMAGES") == "1", "Opt in to the Windows raw-pixel GPU path")
    def test_local_raw_pixels_and_pixel_cleanup(self):
        self.run_scene(graphical=True, raw_pixels=True)

    @unittest.skipUnless(os.environ.get("GRAFFITTY_TEST_GPU_IMAGES") == "1", "Opt in to a real GPU window")
    def test_native_shared_resources_and_pixel_cleanup(self):
        self.run_scene(graphical=True)

    @unittest.skipUnless(os.environ.get("GRAFFITTY_TEST_GPU_IMAGES") == "1", "Opt in to a real GPU window")
    def test_production_camera_during_preview_churn(self):
        self.run_scene(graphical=True, motion=True)


if __name__ == "__main__":
    unittest.main()
