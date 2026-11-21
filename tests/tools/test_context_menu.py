"""Exercise file-manager adapters with real argv, including hostile filenames."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
import unicodedata
import shutil
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("context_menu", ROOT / "tools/install_context_menu.py")
menu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(menu)


class ContextMenuTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def capture(self, command_suffix=()):
        result = self.root / "result.json"
        launcher = self.root / 'launcher space \' $`%"'
        launcher.write_text(
            '#!/bin/sh\nexec ' + shlex.join([sys.executable, '-c',
            'import json,sys; from pathlib import Path; '
            f'Path({str(result)!r}).write_text(json.dumps(sys.argv[1:]))']) + ' "$@"\n'
        )
        launcher.chmod(0o755)
        command = [str(launcher), *command_suffix]
        return command, result

    def test_local_directory_is_one_literal_argument(self):
        directory = self.root / 'space 한글 " $(touch INJECTED) `id` % newline\nfolder'
        directory.mkdir()
        for suffix in ((), ("--",)):
            with self.subTest(suffix=suffix):
                command, result = self.capture(suffix)
                result.unlink(missing_ok=True)
                subprocess.run(["/bin/sh", "-c", menu.folder_script(command), "adapter",
                                str(directory)], check=True, cwd=self.root)
                for _ in range(100):
                    if result.exists() and result.stat().st_size:
                        break
                    time.sleep(0.02)
                self.assertEqual(json.loads(result.read_text()), [*suffix, "--cwd=" + str(directory)])
                self.assertFalse((self.root / "INJECTED").exists())

    def test_empty_remote_or_file_selection_does_not_open_wrong_directory(self):
        command, result = self.capture()
        file = self.root / "file"
        file.touch()
        subprocess.run(["/bin/sh", "-c", menu.folder_script(command), "adapter",
                        "sftp://example.invalid/folder", str(file), str(self.root / "missing")], check=True)
        self.assertFalse(result.exists())
        subprocess.run(["/bin/sh", "-c", menu.folder_script(command)], check=True)
        self.assertFalse(result.exists())

    def test_relative_selection_is_resolved_before_launch(self):
        command, result = self.capture(("--",))
        directory = self.root / "--folder"
        directory.mkdir()
        subprocess.run(["/bin/sh", "-c", menu.folder_script(command), "adapter", directory.name],
                       cwd=self.root, check=True)
        for _ in range(100):
            if result.exists() and result.stat().st_size:
                break
            time.sleep(0.02)
        actual = json.loads(result.read_text())
        self.assertEqual(actual[0], "--")
        self.assertEqual(Path(actual[1].removeprefix("--cwd=")).resolve(), directory.resolve())

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS AppKit")
    def test_native_finder_service(self):
        command, result = self.capture()
        directory = self.root / '한글 space " $(touch INJECTED) `id` % newline\nfolder'
        directory.mkdir()
        source = ROOT / "frontends/godot/extension/src/folder_services_macos.mm"
        harness = self.root / "service.mm"
        harness.write_text('#import "' + str(source) + '"\n' + r'''
int main(int argc, char **argv) {
    @autoreleasepool {
        GraffittyFolderService *service = [[GraffittyFolderService alloc] init];
        service.launcher = [NSURL fileURLWithPath:@(argv[1])];
        NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
        [board writeObjects:@[[NSURL fileURLWithPath:@(argv[2])]]];
        NSString *error = nil;
        [service openFolders:board userData:nil error:&error];
        [board releaseGlobally];
        return error ? 1 : 0;
    }
}
''')
        binary = self.root / "service"
        subprocess.run(["clang++", "-fobjc-arc", "-framework", "AppKit",
                        str(harness), "-o", str(binary)], check=True)
        # Invalid selections must not launch a terminal at an unintended cwd.
        file = self.root / "file"
        file.touch()
        for selection in (file, self.root / "missing"):
            subprocess.run([str(binary), command[0], str(selection)], check=True)
            self.assertFalse(result.exists())
        subprocess.run([str(binary), command[0], str(directory)], check=True)
        for _ in range(100):
            if result.exists() and result.stat().st_size:
                break
            time.sleep(0.02)
        # AppKit returns the filesystem's decomposed Unicode spelling.
        self.assertEqual([unicodedata.normalize("NFC", arg)
                          for arg in json.loads(result.read_text())],
                         ["--cwd=" + unicodedata.normalize("NFC", str(directory))])
        self.assertFalse((self.root / "INJECTED").exists())

    def test_install_uninstall_in_isolated_user_directories(self):
        command, _ = self.capture()
        for platform in ("linux",):
            with self.subTest(platform=platform), patch.object(menu.sys, "platform", platform), \
                 patch.object(menu.Path, "home", return_value=self.root), \
                 patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root / "data space")}), \
                 patch.object(menu.sys, "argv", ["installer", "--launcher", command[0]]):
                menu.main()
                paths = menu.linux_files(self.root / "data space", command)
                for path, (_, mode) in paths.items():
                    self.assertTrue(path.is_file())
                    self.assertEqual(path.stat().st_mode & 0o777, mode)
                with patch.object(menu.sys, "argv", ["installer", "--uninstall"]):
                    menu.main()
                    menu.main()
                self.assertFalse(any(path.exists() for path in paths))

    def test_linux_bundle_launcher_discovery(self):
        bundle = self.root / "bundle space"
        (bundle / "tools").mkdir(parents=True)
        shutil.copy2(ROOT / "packaging/linux/install.py", bundle)
        shutil.copy2(ROOT / "tools/install_context_menu.py", bundle / "tools")
        launcher = bundle / "gft-gui"
        launcher.write_text("#!/bin/sh\nexit 0\n")
        launcher.chmod(0o755)
        # Run the Linux-only installer under the host Python with platform patched.
        bootstrap = ("import runpy,sys; sys.platform='linux'; "
                     "sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')")
        data = self.root / "data"
        env = {**os.environ, "XDG_DATA_HOME": str(data)}
        # Verify bundle launcher discovery and its required Godot separator.
        script = bundle / "tools/install_context_menu.py"
        subprocess.run([sys.executable, "-c", bootstrap, str(script)], env=env, check=True)
        helper = data / "graffitty/open-folder"
        self.assertIn(shlex.join([str(launcher.resolve()), "--"]), helper.read_text())
        subprocess.run([sys.executable, "-c", bootstrap, str(script), "--uninstall"],
                       env=env, check=True)
        self.assertFalse(helper.exists())

    def test_desktop_exec_escapes_percent_and_shell_metacharacters(self):
        # Undo desktop-file string escaping, then the Exec argument quoting.
        original = '/tmp/space " $ ` \\ %F/open-folder'
        encoded = menu.desktop_quote(original)
        decoded_string = encoded.replace('\\\\', '\\')
        self.assertEqual(shlex.split(decoded_string)[0].replace('\\$', '$').replace('\\`', '`'),
                         original.replace('%', '%%'))


if __name__ == "__main__":
    unittest.main()
