"""Check native task staging and command construction without building or launching apps."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import tomllib

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tools",)]
import build_chromium_video
import build_chromium_video_linux
import build_godot
import mise_tasks as tasks
from build_environment import native_build_environment


class NativeTasksTests(unittest.TestCase):
    def test_reload_skips_build_and_server_restart_but_reaches_godot(self):
        for reload_scripts in (False, True):
            with self.subTest(reload=reload_scripts), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                project = root / "frontends/godot/project"
                (project / ".godot").mkdir(parents=True)
                (project / ".godot/extension_list.cfg").touch()
                with (
                    patch.object(tasks, "ROOT", root),
                    patch.object(tasks, "godot", return_value="godot"),
                    patch.object(tasks, "run") as run,
                    patch.object(tasks, "stage"),
                    patch.object(tasks, "prepare_godot_links", return_value=False),
                    patch.object(tasks, "restart_if_requested") as restart,
                    patch.dict(os.environ, {"XDG_STATE_HOME": str(root / "state")}),
                ):
                    tasks.dev(["--reload"] if reload_scripts else [])
                builds = [call for call in run.call_args_list if call.args[:3] == ("mise", "run", "dev:build")]
                self.assertEqual(len(builds), 0 if reload_scripts else 1)
                self.assertEqual(restart.call_count, 0 if reload_scripts else 1)
                self.assertEqual("--reload" in run.call_args_list[-1].args, reload_scripts)

    @unittest.skipUnless(os.name == "nt", "Windows Git symlink repair")
    def test_git_link_placeholder_becomes_working_native_link(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            project = root / "frontends/godot/project"
            project.mkdir(parents=True)
            (root / "assets/branding").mkdir(parents=True)
            (root / "assets/branding/icon.png").write_bytes(b"icon")
            link = project / "assets"
            link.write_bytes(b"../../../assets")

            def git(*args, **kwargs):
                output = (
                    b"120000 abc123 0\tfrontends/godot/project/assets\0"
                    if args[1] == "ls-files"
                    else b"../../../assets"
                )
                return subprocess.CompletedProcess(args, 0, stdout=output)

            with (
                patch.object(tasks, "ROOT", root),
                patch.object(tasks, "run", side_effect=git),
            ):
                self.assertTrue(tasks.prepare_godot_links(project))
                self.assertEqual((link / "branding/icon.png").read_bytes(), b"icon")
                self.assertFalse(tasks.prepare_godot_links(project))

    @unittest.skipUnless(os.name == "nt", "Windows launch setup")
    def test_dev_imports_only_when_extension_registry_is_missing(self):
        for imported in (False, True):
            with self.subTest(imported=imported), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                project = root / "frontends/godot/project"
                if imported:
                    (project / ".godot").mkdir(parents=True)
                    (project / ".godot/extension_list.cfg").write_text("registry")
                with (
                    patch.object(tasks, "ROOT", root),
                    patch.object(tasks, "godot", return_value="godot.exe"),
                    patch.object(tasks, "run") as run,
                    patch.dict(os.environ, {"XDG_STATE_HOME": str(root / "state")}),
                ):
                    tasks.dev([])
                imports = [
                    call for call in run.call_args_list if "--import" in call.args
                ]
                self.assertEqual(len(imports), 0 if imported else 1)
                self.assertEqual(run.call_args_list[-1].args[0], "godot.exe")
                env = run.call_args_list[-1].kwargs["env"]
                self.assertEqual(env["PATH"].split(os.pathsep)[0], str(root / "dist/bin"))

    @unittest.skipUnless(os.name == "nt", "Windows build dispatch")
    def test_godot_build_uses_native_powershell_and_preserves_failure(self):
        with patch.object(
            build_godot.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 19),
        ) as run:
            self.assertEqual(build_godot.main([]), 19)
        command = run.call_args.args[0]
        self.assertEqual(command[0], "powershell.exe")
        self.assertTrue(command[command.index("-File") + 1].endswith("build-windows.ps1"))
        self.assertEqual(command[-2:], ["-BuildProfile", "release"])
        self.assertNotIn("bash", command)

    @unittest.skipIf(os.name == "nt", "POSIX hosts build in Python")
    def test_godot_build_profile_selects_cargo_output_and_stages_it(self):
        for argv, profile, output in (([], "release", "release"), (["--profile", "dev"], "dev", "debug")):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                (root / "zig/bin").mkdir(parents=True)
                (root / "zig/bin/zig").touch()
                library = root / "target" / output / "libgraffitty.so"
                library.parent.mkdir(parents=True)
                library.write_bytes(b"graffitty")

                def fake_run(command, root=root, **kwargs):
                    stdout = {
                        ("mise", "where"): f"{root / 'zig'}\n",
                        ("cargo", "metadata"): json.dumps({"target_directory": str(root / "target")}),
                    }.get(tuple(command[:2]))
                    return subprocess.CompletedProcess(command, 0, stdout=stdout)

                with (
                    patch.object(build_godot, "STAGED", root / "bin"),
                    patch.object(build_godot, "library_names", return_value=("libgraffitty.so", "staged.so")),
                    patch.object(build_godot.subprocess, "run", side_effect=fake_run) as run,
                    patch("builtins.print"),
                ):
                    self.assertEqual(build_godot.main(argv), 0)
                cargo = next(c.args[0] for c in run.call_args_list if c.args[0][:2] == ["cargo", "build"])
                self.assertEqual(cargo[cargo.index("--profile") + 1], profile)
                self.assertEqual((root / "bin/staged.so").read_bytes(), b"graffitty")

    def test_godot_build_stages_names_the_extension_manifest_loads(self):
        manifest = (tasks.ROOT / "frontends/godot/project/addons/graffitty/graffitty.gdextension").read_text()
        for host, machine in (("darwin", "arm64"), ("linux", "x86_64"), ("linux", "aarch64")):
            with (
                self.subTest(host=host, machine=machine),
                patch.object(build_godot.sys, "platform", host),
                patch.object(build_godot.platform, "machine", return_value=machine),
            ):
                self.assertIn(f'"res://addons/graffitty/bin/{build_godot.library_names()[1]}"', manifest)

    def test_mise_dev_selects_dev_profile_without_changing_release_build(self):
        config = tomllib.loads((tasks.ROOT / "mise.toml").read_text())
        self.assertIn("--profile dev", config["tasks"]["dev:build"]["run"])
        self.assertNotIn("--profile dev", config["tasks"]["godot:build"]["run"])

    def test_mise_commands_do_not_require_a_unix_shell(self):
        config = tomllib.loads((tasks.ROOT / "mise.toml").read_text())
        for name, task in config["tasks"].items():
            with self.subTest(task=name):
                self.assertNotIn("shell", task)
                self.assertNotIn("bash", task["run"])
                self.assertNotIn("python3", task["run"])
                self.assertEqual(task["dir"], "{{ config_root }}")

    def test_windows_core_stages_executables_from_cargo_target_directory(self):
        with tempfile.TemporaryDirectory(prefix="native tasks ") as name:
            root = Path(name)
            release = root / "custom target/release"
            release.mkdir(parents=True)
            (release / "gft.exe").write_bytes(b"cli")
            with (
                patch.object(tasks, "ROOT", root),
                patch.object(tasks, "SUFFIX", ".exe"),
                patch.object(tasks, "run") as run,
                patch.object(tasks, "target_directory", return_value=release.parent),
            ):
                tasks.build("core")
            self.assertFalse((root / "tools").exists())
            self.assertEqual(run.call_args_list[0].args, ("uv", "run", root / "tools/build_info.py"))
            run.assert_any_call(
                "cargo",
                "build",
                "--release",
                "--locked",
                "-p",
                "graffitty-cli",
                env=native_build_environment(),
            )
            # The server's filetree runtime is staged after the CLI.
            run.assert_called_with(sys.executable, root / "tools/build_filetree_runtime.py")
            self.assertEqual((root / "dist/bin/gft.exe").read_bytes(), b"cli")
            self.assertEqual((root / "dist/bin/gft-gui.cmd").read_bytes(), b'@"%~dp0gft.exe" gui %*\r\n')
            self.assertFalse((root / "dist/bin/gft-gui.exe").exists())
            self.assertFalse((root / "dist/bin/gft-server.exe").exists())

    @unittest.skipIf(os.name == "nt", "Windows prepares video through PowerShell")
    def test_posix_core_builds_pinned_video_before_cargo(self):
        with tempfile.TemporaryDirectory(prefix="native tasks ") as name:
            root = Path(name)
            release = root / "target/release"
            release.mkdir(parents=True)
            (release / "gft").write_bytes(b"cli")
            with (
                patch.object(tasks, "ROOT", root),
                patch.object(tasks, "SUFFIX", ""),
                patch.object(tasks, "run") as run,
                patch.object(tasks, "target_directory", return_value=release.parent),
            ):
                tasks.build("core")
            commands = [call.args[:2] for call in run.call_args_list]
            video = commands.index((sys.executable, root / "tools/build_chromium_video.py"))
            self.assertLess(video, commands.index(("cargo", "build")))

    def test_linux_video_build_uses_the_linux_recipe(self):
        target = "x86_64-unknown-linux-gnu"
        with (
            patch.object(build_chromium_video.subprocess, "check_output", return_value="host: x\n"),
            patch.object(build_chromium_video_linux, "build", return_value=Path("prefix")) as linux,
        ):
            self.assertEqual(build_chromium_video.build(target), Path("prefix"))
        linux.assert_called_once_with(
            build_chromium_video.ROOT, target, build_chromium_video.VERSION, build_chromium_video.SHA256
        )

    def test_unchanged_staging_does_not_replace_binary(self):
        with tempfile.TemporaryDirectory() as name:
            source, dest = Path(name) / "source", Path(name) / "dest"
            source.write_bytes(b"same")
            dest.write_bytes(b"same")
            with patch.object(tasks.tempfile, "mkstemp") as create:
                tasks.stage(source, dest)
            create.assert_not_called()

    def test_failed_build_does_not_stage(self):
        with (
            patch.object(
                tasks, "run", side_effect=subprocess.CalledProcessError(17, ["cargo"])
            ),
            patch.object(tasks, "stage") as stage,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                tasks.build("cli")
            stage.assert_not_called()

    def test_git_paths_keep_spaces_and_skip_deleted_files(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "space name.gd").touch()
            result = subprocess.CompletedProcess(
                [], 0, stdout=b"space name.gd\0deleted.gd\0"
            )
            with (
                patch.object(tasks, "ROOT", root),
                patch.object(tasks, "run", return_value=result),
            ):
                self.assertEqual(tasks.git_files("*.gd"), ["space name.gd"])

    def test_sdk_environment_override(self):
        with patch.dict(
            os.environ,
            {"ANDROID_HOME": "C:/SDK with spaces", "ANDROID_SDK_ROOT": "C:/other"},
        ):
            self.assertEqual(tasks.android_sdk(), Path("C:/SDK with spaces"))

    def test_failure_exit_code_is_preserved(self):
        with (
            patch.object(tasks.sys, "argv", ["mise_tasks.py", "core:build"]),
            patch.object(
                tasks, "build", side_effect=subprocess.CalledProcessError(23, ["cargo"])
            ),
        ):
            self.assertEqual(tasks.main(), 23)


if __name__ == "__main__":
    unittest.main()
