"""Launch isolation and fail-closed evidence checks for GPU E2E runs."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "e2e_background", Path(__file__).resolve().parents[2] / "tests/support/e2e_background.py"
)
background = importlib.util.module_from_spec(spec)
spec.loader.exec_module(background)


class BackgroundTests(unittest.TestCase):
    def report(self, directory, name="native.json", **values):
        report = dict(pid=123, samples=12, visible_samples=0, active_samples=0)
        report.update(values)
        (Path(directory) / name).write_text(json.dumps(report))

    def test_unsupported_platform_requires_explicit_headful(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(background.sys, "platform", "linux"),
        ):
            env = {"USER_FLAG": "keep"}
            with self.assertRaisesRegex(RuntimeError, "--headful"):
                background.prepare_background(env, Path(directory))
            self.assertEqual(env, {"USER_FLAG": "keep"})

    def test_launch_preserves_unrelated_injection_and_clears_inherited_handshake(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(background.sys, "platform", "darwin"),
            patch.object(
                background,
                "_guard_library",
                return_value=Path(
                    "/private/graffitty-e2e-native-new/e2e_background_guard.dylib"
                ),
            ),
        ):
            old_library = "/private/graffitty-e2e-native-old/e2e_background_guard.dylib"
            env = dict(
                DYLD_INSERT_LIBRARIES=f"/third-party.dylib:{old_library}",
                GRAFFITTY_E2E_GUARD_ACTIVE="555",
                GRAFFITTY_E2E_NATIVE_PRIMARY_PID="555",
                GRAFFITTY_E2E_NATIVE_LIBRARY=old_library,
            )
            args = background.prepare_background(env, Path(directory))
            self.assertEqual(env["GRAFFITTY_E2E_BACKGROUND"], "1")
            self.assertEqual(
                Path(env["GRAFFITTY_E2E_NATIVE_REPORT"]),
                Path(directory).resolve() / "native.json",
            )
            self.assertNotIn("GRAFFITTY_E2E_GUARD_ACTIVE", env)
            self.assertNotIn("GRAFFITTY_E2E_NATIVE_PRIMARY_PID", env)
            self.assertEqual(
                env["DYLD_INSERT_LIBRARIES"],
                "/private/graffitty-e2e-native-new/e2e_background_guard.dylib:/third-party.dylib",
            )
            self.assertEqual(
                args,
                [
                    "--rendering-driver",
                    "metal",
                    "--rendering-method",
                    "forward_plus",
                    "--disable-render-loop",
                    "--max-fps",
                    "60",
                    "--audio-driver",
                    "Dummy",
                ],
            )
            background.clear_background(env)
            self.assertEqual(env, {"DYLD_INSERT_LIBRARIES": "/third-party.dylib"})

    def test_headful_cleanup_handles_already_filtered_environment(self):
        env = dict(
            DYLD_INSERT_LIBRARIES="/private/graffitty-e2e-native-old/e2e_background_guard.dylib"
        )
        background.clear_background(env)
        self.assertEqual(env, {})

    def test_compilation_removes_inherited_guard_and_preserves_other_injections(self):
        old_library = "/private/graffitty-e2e-native-old/e2e_background_guard.dylib"
        inherited = dict(
            DYLD_INSERT_LIBRARIES=f"{old_library}:/third-party.dylib",
            GRAFFITTY_E2E_BACKGROUND="1",
            GRAFFITTY_E2E_GUARD_ACTIVE="555",
            GRAFFITTY_E2E_NATIVE_PRIMARY_PID="555",
            GRAFFITTY_E2E_NATIVE_LIBRARY=old_library,
            COMPILER_OPTION="keep",
        )
        with (
            patch.dict(background.os.environ, inherited, clear=True),
            patch.object(background, "_guard_cache", {}),
            patch.object(background.shutil, "which", return_value="/usr/bin/clang"),
            patch.object(
                background.subprocess,
                "run",
                return_value=background.subprocess.CompletedProcess([], 0, "", ""),
            ) as compile_guard,
        ):
            try:
                background._guard_library()
                self.assertEqual(
                    compile_guard.call_args.kwargs["env"],
                    {
                        "DYLD_INSERT_LIBRARIES": "/third-party.dylib",
                        "COMPILER_OPTION": "keep",
                    },
                )
                self.assertEqual(dict(background.os.environ), inherited)
            finally:
                for directory, _library in background._guard_cache.values():
                    directory.cleanup()

    @unittest.skipUnless(
        background.sys.platform == "darwin" and background.shutil.which("clang"),
        "The native guard uses macOS AppKit",
    )
    def test_loaded_guard_removes_only_its_own_injection(self):
        """Exercise the real constructor before descendants can load this dylib."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            other = root / "other.dylib"
            application = root / "fixture"
            compiler_env = background.os.environ.copy()
            background.clear_background(compiler_env)
            for command, source in (
                (
                    ["clang", "-dynamiclib", "-x", "c", "-", "-o", str(other)],
                    "int background_test_fixture(void) { return 1; }",
                ),
                (
                    [
                        "clang",
                        "-x",
                        "objective-c",
                        "-",
                        "-framework",
                        "Foundation",
                        "-o",
                        str(application),
                    ],
                    """
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
@interface GodotApplication : NSObject @end
@implementation GodotApplication @end
int main(void) {
    const char *injected = getenv("DYLD_INSERT_LIBRARIES");
    const char *active = getenv("GRAFFITTY_E2E_GUARD_ACTIVE");
    printf("%s\\n%s\\n%d\\n", injected ? injected : "<unset>",
           active ? active : "", getpid());
    return 0;
}
""",
                ),
            ):
                result = background.subprocess.run(
                    command,
                    input=source,
                    capture_output=True,
                    text=True,
                    env=compiler_env,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
            for name, libraries in (
                ("alone", []),
                ("others", [str(other), str(other)]),
            ):
                with self.subTest(name=name):
                    env = compiler_env.copy()
                    env.pop("DYLD_INSERT_LIBRARIES", None)
                    background.prepare_background(env, root / name)
                    guard = env["GRAFFITTY_E2E_NATIVE_LIBRARY"]
                    env["DYLD_INSERT_LIBRARIES"] = ":".join(
                        [*libraries[:1], guard, *libraries[1:], guard]
                    )
                    result = background.subprocess.run(
                        [str(application)],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    remaining, active, pid = result.stdout.splitlines()
                    self.assertEqual(remaining, ":".join(libraries) or "<unset>")
                    self.assertEqual(
                        active, pid, "The native constructor ran in this process"
                    )

    def test_stale_evidence_cannot_make_an_uninstrumented_run_pass(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(background.sys, "platform", "darwin"),
            patch.object(background, "_guard_library") as compile_guard,
        ):
            self.report(directory)
            with self.assertRaisesRegex(RuntimeError, "fresh evidence"):
                background.prepare_background({}, Path(directory))
            compile_guard.assert_not_called()

    def test_requires_primary_even_when_child_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            self.report(directory, "native-123.json")
            self.assertIn(
                "missing", " ".join(background.background_failures(Path(directory)))
            )

    def test_checks_primary_pid_sampling_and_every_child(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            self.report(directory)
            self.report(directory, "native-456.json", pid=456, samples=1)
            self.assertEqual(background.background_failures(evidence, pid=123), [])
            self.report(
                directory,
                "native-456.json",
                pid=456,
                samples=0,
                visible_samples=1,
                active_samples=2,
            )
            errors = " ".join(background.background_failures(evidence, pid=789))
            for expected in (
                "does not match primary PID",
                "expected at least 1",
                "window was visible",
                "app was active",
            ):
                self.assertIn(expected, errors)
            self.report(directory, samples=9)
            self.assertIn(
                "expected at least 10",
                " ".join(background.background_failures(evidence)),
            )

    def test_malformed_report_is_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            for value in (
                "{",
                "[]",
                '{"pid":123}',
                '{"pid":123,"samples":true,"visible_samples":0,"active_samples":0}',
            ):
                with self.subTest(value=value):
                    (evidence / "native.json").write_text(value)
                    self.assertTrue(background.background_failures(evidence))


if __name__ == "__main__":
    unittest.main()
