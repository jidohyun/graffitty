"""Check mode propagation and native evidence handling for simulated clients."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import test_android_runtime as runner


class SimulatedRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)

    def launch(self, command, **kwargs):
        (self.output / "runtime-state.json").write_text(json.dumps({"failures": []}))
        return subprocess.CompletedProcess(command, 0)

    @staticmethod
    def prepare(env, evidence):
        env["GRAFFITTY_E2E_BACKGROUND"] = "1"
        return ["--disable-render-loop", "--rendering-driver", "metal"]

    def test_background_recording_retains_fixed_fps_and_checks_native_evidence(self):
        with (
            patch.dict(os.environ, {"GODOT": "/custom/Godot"}, clear=True),
            patch.object(
                runner, "prepare_background", side_effect=self.prepare
            ) as prepare,
            patch.object(runner, "background_failures", return_value=[]) as evidence,
            patch.object(runner.subprocess, "run", side_effect=self.launch) as launch,
        ):
            runner.simulate(
                self.output, {"scenario": "workspace"}, self.output / "movie.mp4"
            )
        command = launch.call_args.args[0]
        self.assertEqual(command[0], "/custom/Godot")
        self.assertIn("--disable-render-loop", command)
        self.assertEqual(command[command.index("--fixed-fps") + 1], "30")
        self.assertEqual(
            launch.call_args.kwargs["env"]["GRAFFITTY_E2E_BACKGROUND"], "1"
        )
        self.assertEqual(prepare.call_args.args[1], self.output / "background")
        evidence.assert_called_once_with(self.output / "background")

    def test_native_visibility_failure_overrides_successful_scenario(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(runner, "prepare_background", side_effect=self.prepare),
            patch.object(
                runner,
                "background_failures",
                return_value=["native window was visible"],
            ),
            patch.object(runner.subprocess, "run", side_effect=self.launch),
        ):
            with self.assertRaisesRegex(AssertionError, "native window was visible"):
                runner.simulate(self.output, {})

    def test_explicit_and_inherited_headful_bypass_background_setup(self):
        for explicit, inherited in [
            (True, {}),
            (False, {"GRAFFITTY_E2E_HEADFUL": "1"}),
        ]:
            with (
                self.subTest(explicit=explicit),
                patch.dict(os.environ, inherited, clear=True),
                patch.object(runner, "prepare_background") as prepare,
                patch.object(runner, "background_failures") as evidence,
                patch.object(
                    runner.subprocess, "run", side_effect=self.launch
                ) as launch,
            ):
                runner.simulate(self.output, {}, headful=explicit)
                prepare.assert_not_called()
                evidence.assert_not_called()
                self.assertNotIn("--disable-render-loop", launch.call_args.args[0])


class DirectFixtureTests(unittest.TestCase):
    def test_owner_observer_uses_loopback_without_rewriting_device_endpoint(self):
        for remote, local in [("ws://192.0.2.1:7183", "ws://127.0.0.1:7183"),
                              ("ws://[2001:db8::1]:7183", "ws://[::1]:7183")]:
            descriptor = {"url": remote, "token": "remote-test-password", "local": {"token": "local-test-capability"}}
            observer = runner.local_fixture_connection(descriptor)
            self.assertEqual(observer["url"], local)
            self.assertEqual(observer["local"], descriptor["local"])
            self.assertEqual(descriptor["url"], remote)


class DeviceApkCacheTests(unittest.TestCase):
    def test_identical_apks_upload_once_but_install_each_time_and_clean_up(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            apk.write_bytes(b"first complete APK")
            cache = runner.DeviceApkCache(["adb", "-s", "test-device"])
            success = subprocess.CompletedProcess([], 0, "Success\n", "")
            with patch.object(runner, "run", return_value=success) as run, patch.object(runner.subprocess, "run") as cleanup:
                try:
                    cache(cache.adb, apk)
                    cache(cache.adb, apk)
                    apk.write_bytes(b"changed complete APK")
                    cache(cache.adb, apk)
                    commands = [call.args[0] for call in run.call_args_list]
                    pushes = [command for command in commands if "push" in command]
                    installs = [command for command in commands if "install" in command]
                    self.assertEqual(len(pushes), 2)
                    self.assertEqual(len(installs), 3)
                    self.assertEqual(installs[0], installs[1])
                    self.assertNotEqual(installs[1][-1], installs[2][-1])
                    self.assertTrue(all(command[-1].endswith(".apk") for command in installs))
                    self.assertFalse(any("--incremental" in command for command in commands))
                finally:
                    cache.close()
                self.assertEqual(cleanup.call_count, 2)

    def test_package_manager_failure_is_not_successful_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            apk.write_bytes(b"APK")
            cache = runner.DeviceApkCache(["adb"])
            failure = subprocess.CompletedProcess([], 0, "Failure [INSTALL_FAILED]\n", "")
            with patch.object(runner, "run", return_value=failure), patch.object(runner.subprocess, "run"):
                try:
                    with self.assertRaisesRegex(AssertionError, "INSTALL_FAILED"):
                        cache(cache.adb, apk)
                finally:
                    cache.close()

    def test_missing_device_cache_is_uploaded_again_before_install(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            apk.write_bytes(b"APK")
            cache = runner.DeviceApkCache(["adb"])
            def execute(command, **kwargs):
                if "test" in command:
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0, "Success\n", "")
            with patch.object(runner, "run", side_effect=execute) as run, patch.object(runner.subprocess, "run"):
                try:
                    cache(cache.adb, apk)
                    cache(cache.adb, apk)
                    self.assertEqual(sum("push" in call.args[0] for call in run.call_args_list), 2)
                    self.assertEqual(sum("install" in call.args[0] for call in run.call_args_list), 2)
                finally:
                    cache.close()


if __name__ == "__main__":
    unittest.main()
