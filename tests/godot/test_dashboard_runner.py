"""Mode routing and failure propagation for the visual E2E dashboard."""

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "dashboard_runner", ROOT / "tests/godot/test_dashboard.py"
)
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


class DashboardModes(unittest.TestCase):
    def test_inherited_pixel_assertions_require_gpu(self):
        self.assertTrue(dashboard.needs_window(
            dashboard.GODOT_ROOT / "tests/scatter_camera_flight_smoke.gd"))
        self.assertFalse(dashboard.needs_window(
            ROOT / "tests/llm-e2e/suites/godot/tabs-and-panes/replays/pane-to-new-tab.gd"))

    def setUp(self):
        owner = patch.object(dashboard, "PrivateServer", side_effect=lambda *_: contextlib.nullcontext())
        owner.start()
        self.addCleanup(owner.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.scratch = Path(self.temp.name)
        self.visual = next(
            c for c in dashboard.cases() if c["name"] == "zoomed-text-stays-sharp"
        )
        self.logic = {**self.visual, "name": "logic"}
        self.native = {**self.visual, "name": "native", "requires_headful": True}

    def run_case(self, case, *, headful=False, visual=True, native_errors=(), output="FIXTURE_REPLAY_PASS\n"):
        with (
            patch.object(dashboard, "needs_window", return_value=visual),
            patch.object(dashboard.tempfile, "mkdtemp", return_value=str(self.scratch)),
            patch.object(
                dashboard, "prepare_background", return_value=["--disable-render-loop"]
            ) as prepare,
            patch.object(
                dashboard, "background_failures", return_value=list(native_errors)
            ),
            patch.object(
                dashboard.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    [], 0, output, ""
                ),
            ) as run,
        ):
            result = dashboard.test_one(case, "person.app", headful=headful)
        return result, run.call_args, prepare.called

    def test_engine_diagnostic_overrides_success_marker_and_exit_code(self):
        for diagnostic in ["ERROR: Invalid property", "WARNING: Unknown effect option"]:
            with self.subTest(diagnostic=diagnostic):
                result, _, _ = self.run_case(
                    self.visual, output=diagnostic + "\nFIXTURE_REPLAY_PASS\n")
                self.assertEqual(result["status"], "fail")
                self.assertIn(diagnostic, result["failed"])

    def test_visual_defaults_to_background_with_real_renderer(self):
        result, call, prepared = self.run_case(self.visual)
        self.assertTrue(prepared)
        self.assertEqual(result["mode"], "background")
        self.assertEqual(result["status"], "pass")
        self.assertIn("--disable-render-loop", call.args[0])
        self.assertNotIn("--headless", call.args[0])
        self.assertNotIn("REPLAY_RETURN_FOCUS", call.kwargs["env"])

    def test_headful_opens_even_logic_replays(self):
        result, call, prepared = self.run_case(self.logic, visual=False, headful=True)
        self.assertFalse(prepared)
        self.assertEqual(result["mode"], "headful")
        self.assertNotIn("--headless", call.args[0])
        self.assertEqual(call.kwargs["env"]["GRAFFITTY_E2E_HEADFUL"], "1")

    def test_logic_keeps_dummy_renderer(self):
        result, call, prepared = self.run_case(self.logic, visual=False)
        self.assertFalse(prepared)
        self.assertEqual(result["mode"], "headless")
        self.assertIn("--headless", call.args[0])

    def test_remote_fixture_stays_headless_with_background_environment(self):
        result, call, prepared = self.run_case({**self.visual, "record_client": True})
        self.assertTrue(prepared)
        self.assertEqual(result["mode"], "background")
        self.assertIn("--headless", call.args[0])
        self.assertNotIn("--disable-render-loop", call.args[0])

    def test_native_guard_failure_overrides_replay_pass(self):
        result, _, _ = self.run_case(
            self.visual, native_errors=["native window became visible"]
        )
        self.assertEqual(result["status"], "fail")
        self.assertIn("native window became visible", result["failed"])
        self.assertIn("native window became visible", Path(result["log"]).read_text())

    def test_missing_background_support_does_not_launch_a_window(self):
        with (
            patch.object(dashboard.tempfile, "mkdtemp", return_value=str(self.scratch)),
            patch.object(
                dashboard,
                "prepare_background",
                side_effect=RuntimeError("Use --headful"),
            ),
            patch.object(dashboard.subprocess, "run") as run,
        ):
            result = dashboard.test_one(self.visual, "")
        run.assert_not_called()
        self.assertEqual(result["status"], "fail")
        self.assertIn("Use --headful", result["failed"])

    def test_default_includes_pixels_but_skips_native_focus(self):
        with (
            patch.object(
                dashboard, "cases", return_value=[self.logic, self.visual, self.native]
            ),
            patch.object(dashboard, "needs_window", side_effect=lambda p: True),
            patch.object(
                dashboard,
                "test_one",
                return_value={
                    "mode": "background",
                    "status": "pass",
                    "failed": [],
                    "wall_s": 0,
                    "log": str(self.scratch / "replay.log"),
                },
            ) as run,
            patch.object(dashboard, "frontmost_app") as frontmost,
            contextlib.redirect_stdout(io.StringIO()) as output,
            self.assertRaises(SystemExit) as exited,
        ):
            dashboard.test([], 1)
        self.assertEqual(exited.exception.code, 0)
        self.assertEqual(
            [c.args[0]["name"] for c in run.call_args_list],
            ["logic", self.visual["name"]],
        )
        self.assertIn("add --headful", output.getvalue())
        frontmost.assert_not_called()

    def test_named_native_focus_requires_explicit_opt_in(self):
        with (
            patch.object(dashboard, "cases", return_value=[self.native]),
            self.assertRaises(SystemExit) as exited,
        ):
            dashboard.test(["native"], 1)
        self.assertIn("requires --headful", str(exited.exception))

    def test_recording_routes_background_headful_and_remote_client(self):
        for headful, remote in [(False, False), (True, False), (False, True)]:
            with (
                self.subTest(headful=headful, remote=remote),
                patch.object(dashboard, "MEDIA", self.scratch),
                patch.object(
                    dashboard.tempfile, "mkdtemp", return_value=str(self.scratch)
                ),
                patch.object(dashboard, "check_encoder", return_value="ffmpeg"),
                patch.object(dashboard, "frontmost_app", return_value="person.app"),
                patch.object(
                    dashboard,
                    "prepare_background",
                    return_value=["--disable-render-loop"],
                ) as prepare,
                patch.object(dashboard, "background_failures", return_value=[]),
                patch.object(
                    dashboard.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(
                        [], 0, "FIXTURE_REPLAY_PASS\n", ""
                    ),
                ) as run,
            ):
                dashboard.record_one(
                    {**self.visual, "record_client": remote}, headful=headful
                )
                command = run.call_args.args[0]
                self.assertEqual(prepare.called, not headful)
                self.assertEqual(
                    "--disable-render-loop" in command, not headful and not remote
                )
                self.assertEqual("--headless" in command, remote)
                self.assertEqual("--write-movie" in command, not remote)
                self.assertEqual(
                    any(arg.startswith("--remote-movie=") for arg in command), remote
                )
                self.assertEqual(
                    run.call_args.kwargs["env"]["GRAFFITTY_E2E_HEADFUL"],
                    "1" if headful else "0",
                )

    def test_recording_cannot_pass_with_native_visibility_failure(self):
        def render(command, **_kwargs):
            if "--write-movie" in command:
                Path(command[command.index("--write-movie") + 1]).write_bytes(
                    b"fixture"
                )
            return subprocess.CompletedProcess(
                command, 0, "FIXTURE_REPLAY_PASS\nAV1_MOVIE_PASS\n", ""
            )

        with (
            patch.object(dashboard, "MEDIA", self.scratch),
            patch.object(dashboard.tempfile, "mkdtemp", return_value=str(self.scratch)),
            patch.object(dashboard, "check_encoder", return_value="ffmpeg"),
            patch.object(dashboard, "prepare_background", return_value=[]),
            patch.object(
                dashboard, "background_failures", return_value=["visible test window"]
            ),
            patch.object(
                dashboard, "probe_av1", return_value=({"format": {"duration": "1"}}, {})
            ),
            patch.object(dashboard.subprocess, "run", side_effect=render),
        ):
            result = dashboard.record_one(self.visual)
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["codec"], "unverified")


if __name__ == "__main__":
    unittest.main()
