"""Stdlib checks; GPU integration is tests/virtual_terminal_input_smoke.gd."""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader(
    "record_effects", str(ROOT / "videos/effects/recording/record.py")
)
spec = importlib.util.spec_from_loader(loader.name, loader)
recorder = importlib.util.module_from_spec(spec)
loader.exec_module(recorder)


class CaptureTests(unittest.TestCase):
    def test_terminal_cli_sends_scoped_unicode_and_modifiers(self):
        for arguments, expected in [
            (
                ["type", "--text", "한🙂", "--interval-ms", "20"],
                ("terminal.type", {"text": "한🙂", "interval_ms": 20}),
            ),
            (["send-key", "Ctrl+u"], ("terminal.press", {"key": "Ctrl+u"})),
            (["send-key", "Ctrl+h", "--no-effects"], ("terminal.press", {"key": "Ctrl+h", "effects": False})),
        ]:
            with (
                self.subTest(arguments=arguments),
                tempfile.TemporaryDirectory(prefix="tc-", dir="/tmp") as tmp,
            ):
                endpoint = str(Path(tmp) / "api.sock")
                received = []
                with socket.socket(socket.AF_UNIX) as server:
                    server.bind(endpoint)
                    server.listen(1)
                    server.settimeout(5)

                    def respond(received=received):
                        with server.accept()[0] as client:
                            request = json.loads(client.makefile("rb").readline())
                            received.append(request)
                            client.sendall(
                                (
                                    json.dumps(
                                        {
                                            "id": request["id"],
                                            "result": {"keys_sent": 1},
                                        }
                                    )
                                    + "\n"
                                ).encode()
                            )

                    worker = threading.Thread(target=respond)
                    worker.start()
                    result = subprocess.run(
                        [str(ROOT / "dist/bin/gft"), "terminal", *arguments],
                        env=dict(
                            {key: value for key, value in os.environ.items()
                             if not key.startswith(("CODEX_", "GRAFFITTY_"))},
                            GRAFFITTY_SOCKET=endpoint,
                            GRAFFITTY_TOKEN="owned-test-token",
                        ),
                        text=True,
                        capture_output=True,
                        check=False,
                        timeout=5,
                    )
                    worker.join(5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    (received[0]["method"], received[0]["params"]), expected
                )
                self.assertEqual(received[0]["token"], "owned-test-token")
                self.assertEqual(received[0]["version"], 1)

    def test_catalogue_lists_current_particle_families(self):
        catalog = json.loads(recorder.CATALOG.read_text())
        for name in [
            "particles-" + p
            for p in ["dots", "sparks", "fireworks", "flames", "glitter"]
        ]:
            self.assertIn(name, catalog)
        for name in ["particles-amount", "particles-scale"]:
            self.assertIn(name, catalog)
        self.assertNotIn("combined", catalog)
        self.assertNotIn("tab-transition", catalog)
        result = subprocess.run(
            [str(ROOT / "videos/effects/recording/record.py"), "--list"],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stdout.splitlines(), list(catalog))

    def test_gallery_groups_named_effects_and_marks_missing_previews(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            recorder.write_gallery(target, list(json.loads(recorder.CATALOG.read_text())))
            page = (target / "index.html").read_text()
            for category in ("Typing", "Cursor", "Camera", "Sheet", "Lighting", "Transitions"):
                self.assertIn("<h2>" + category + "</h2>", page)
            self.assertIn("<h3>Lightning</h3>", page)
            self.assertIn("[terminal.effects.cursor_trail]", page)
            self.assertIn("style = &quot;lightning&quot;", page)
            self.assertNotIn("[state.typing]", page)
            self.assertIn("data-copy-settings", page)
            self.assertIn("Preview not recorded yet", page)
            self.assertNotIn("<video ", page)
            self.assertNotIn("autoplay", page)

    def test_gallery_uses_one_user_config_block_for_particles(self):
        catalog = json.loads(recorder.CATALOG.read_text())
        label, code = recorder.gallery_settings(catalog["particles-amount"])
        self.assertEqual(label, "client.toml")
        import tomllib
        self.assertEqual(tomllib.loads(code), {"terminal": {"effects": {
            "typing_particles": {"preset": "sparks", "amount": 90, "scale": 1.4}
        }}})
        block = recorder.gallery_settings_html(catalog["particles-amount"])
        self.assertEqual(block.count("data-copy-settings"), 1)
        self.assertNotIn("[state.typing]", block)
        self.assertNotIn("[scene.typing]", block)
        _, trail = recorder.gallery_settings(catalog["cursor-trail"])
        values = tomllib.loads(trail)["terminal"]["effects"]["cursor_trail"]
        self.assertEqual(values["delay_ms"], 1)
        self.assertEqual(values["decay"], [0.1, 0.4])
        self.assertEqual(values["start_threshold"], [0, 0])

    def test_all_gallery_settings_are_valid_toml(self):
        import tomllib
        for name, case in json.loads(recorder.CATALOG.read_text()).items():
            with self.subTest(effect=name):
                _, code = recorder.gallery_settings(case)
                self.assertTrue(tomllib.loads(code))

    def test_gallery_marks_changed_settings_as_earlier_take(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            directory = target / "cursor-trail-lightning"
            directory.mkdir()
            (directory / "effect.mp4").write_bytes(b"video")
            (directory / "probe.json").write_text("{}")
            case = json.loads(recorder.CATALOG.read_text())[directory.name]
            (directory / "settings.json").write_text(json.dumps(case))
            recorder.write_gallery(target, [directory.name])
            page = (target / "index.html").read_text()
            self.assertIn("<video controls loop muted playsinline", page)
            self.assertNotIn("Earlier take", page)
            case["overrides"] = []
            (directory / "settings.json").write_text(json.dumps(case))
            recorder.write_gallery(target, [directory.name])
            self.assertIn("Earlier take", (target / "index.html").read_text())

    def test_catalogue_covers_menu_styles_and_transition_paths(self):
        catalog = json.loads(recorder.CATALOG.read_text())
        for style in ("smear", "blaze", "lightning"):
            self.assertTrue(any("scene.cursor_trail:style=" + style in case["overrides"]
                                for case in catalog.values()))
        self.assertEqual(catalog["tab-switch-push-pull"]["transition"], "tab")
        self.assertIn("scene.camera:zoom_mode=typing", catalog["camera-zoom"]["overrides"])
        self.assertIn("scene.camera:zoom_mode=adaptive", catalog["camera-adaptive"]["overrides"])
        self.assertEqual(catalog["pane-zoom"]["demo"], "pane_zoom")
        for name in ("session-switch-fly-away", "session-switch-fly-away-and-in"):
            self.assertEqual(catalog[name]["transition"], "session")
        for case in catalog.values():
            for key in ("title", "category"):
                self.assertTrue(case[key])

    def test_export_contains_media_but_no_private_capture_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "capture"
            clip = source / "particles-sparks"
            clip.mkdir(parents=True)
            (clip / "effect.mp4").write_bytes(b"video")
            (clip / "probe.json").write_text("{}")
            (clip / "preview.png").write_bytes(b"poster")
            (clip / "settings.json").write_text('{"output":"private-path"}')
            (clip / "command.json").write_text('["private-command"]')
            target = Path(tmp) / "public"
            docs_page = Path(tmp) / "effects.md"
            docs_page.write_text("# Effects\n\n<!-- Generated effect previews -->\nold content\n")
            recorder.export_gallery(source, target, docs_page)
            guide = docs_page.read_text()
            self.assertNotIn("<iframe", guide)
            self.assertNotIn("old content", guide)
            self.assertIn("data-effects-motion", guide)
            self.assertIn('src="public/particles-sparks/effect.mp4?', guide)
            self.assertTrue((target / "particles-sparks/effect.mp4").exists())
            self.assertFalse(list(target.rglob("*.json")))
            page = (target / "index.html").read_text()
            self.assertNotIn("private-path", page)
            self.assertIn("Earlier take", page)

    def test_private_project_does_not_share_user_preferences(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = recorder.stage_project(Path(tmp), "800x500")
            config = (project / "project.godot").read_text()
            self.assertIn("window/size/viewport_width=800", config)
            self.assertIn("window/size/viewport_height=500", config)
            self.assertNotIn("Godot/app_userdata/godot-ghostty", config)
            self.assertNotIn("config/custom_user_dir_name.linux=", config)
            self.assertTrue((project / "scenes").is_symlink())
            self.assertFalse((project / "project.godot").is_symlink())

    def test_gallery_media_url_changes_with_video_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            clip = target / "sheet-saddle/effect.mp4"
            clip.parent.mkdir()
            clip.write_bytes(b"old recording")
            (clip.parent / "probe.json").write_text("{}")
            recorder.write_gallery(target, ["sheet-saddle"])
            before = (target / "index.html").read_text()
            clip.write_bytes(b"new recording")
            recorder.write_gallery(target, ["sheet-saddle"])
            after = (target / "index.html").read_text()
            self.assertIn("effect.mp4?v=", after)
            self.assertNotEqual(before, after)

    @unittest.skipUnless(
        shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required"
    )
    def test_live_encoding_preserves_irregular_timestamps_at_120_fps(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "frames").mkdir()

            def chunk(kind, data):
                return (
                    struct.pack(">I", len(data))
                    + kind
                    + data
                    + struct.pack(">I", zlib.crc32(kind + data))
                )

            image = (
                b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress((b"\0" + b"\x10\x80\xff" * 64) * 64))
                + chunk(b"IEND", b"")
            )
            times = [0.0, 0.025, 0.099, 0.14, 0.187]
            for index in range(len(times)):
                (directory / f"frames/frame{index:08d}.png").write_bytes(image)
            metadata = {
                "error": "",
                "events": [],
                "size": [64, 64],
                "frames": [{"time": t} for t in times],
            }
            (directory / "capture.json").write_text(json.dumps(metadata))
            recorder.encode(directory, "live", 120)
            probe = json.loads((directory / "probe.json").read_text())
            duration = float(probe["streams"][0]["duration"])
            self.assertAlmostEqual(duration, times[-1] + 1 / 120, delta=2 / 120)
            self.assertGreater(int(probe["streams"][0]["nb_read_frames"]), len(times))

    def test_invalid_size_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "output"
            result = subprocess.run(
                [
                    str(ROOT / "videos/effects/recording/record.py"),
                    "--all",
                    "--resolution",
                    "641x400",
                    "--output",
                    str(target),
                ],
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
