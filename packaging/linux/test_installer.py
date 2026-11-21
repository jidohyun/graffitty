"""Tests for install.sh. Releases come from local fixtures, so nothing is
downloaded. Everything installs into a temporary home."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
ICON_PATHS = [Path(f"icons/hicolor/{size}x{size}/apps/graffitty.png")
              for size in (16, 22, 24, 32, 48, 64, 96, 128, 256, 512)]


def write_release(releases: Path, version: str, gft: Path | None = None, gui: Path | None = None) -> None:
    """Create a test release directory containing one bundle.

    Use the supplied gft binary if present. Otherwise, create a stub
    that records its arguments.
    """
    bundle = releases / version / "graffitty"
    (bundle / "tools").mkdir(parents=True)
    if gft:
        shutil.copy(gft, bundle / "tools/gft")
    else:
        (bundle / "tools/gft").write_text(
            f'#!/bin/sh\necho "{version} $*" >> "$GFT_LOG"\necho "Restarted; 1 terminal(s) kept"\n')
    if gui:
        shutil.copy(gui, bundle / "gft-gui")
    else:
        (bundle / "gft-gui").write_text("#!/bin/sh\n")
    for name in ("tools/gft", "gft-gui"):
        (bundle / name).chmod(0o755)
    for icon in ICON_PATHS:
        (bundle / icon).parent.mkdir(parents=True)
        (bundle / icon).write_text(f"{version} {icon}")
    (bundle / "install.py").write_text("")
    (bundle / "PLATFORM").write_text("linux-x86_64\n")
    names = ("gft-gui", "tools/gft", "install.py", "PLATFORM", *ICON_PATHS)
    (bundle / "SHA256SUMS").write_text(
        "".join(f"{hashlib.sha256((bundle / name).read_bytes()).hexdigest()}  {name}\n" for name in names))
    archive = releases / version / "graffitty-linux-x86_64.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as tar:
        tar.add(bundle, arcname="graffitty")
    # One line per archive: checksum, the name install.sh asks for, and where the
    # file is. Here it sits in a folder beside the listing.
    (releases / f"{version}.txt").write_text(
        f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}  {version}/{archive.name}\n")


def install_script(entry: str = "arch=x86_64\ninstall_linux") -> str:
    """Returns install.sh changed for testing: it runs `entry` (one platform's
    install function) and skips detection. Releases come from the local
    directory in GRAFFITTY_RELEASES, which the script supports itself."""
    script = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
    return script + "\n" + entry + "\n"


class InstallerTests(unittest.TestCase):
    def select(self, glibc=None, musl=False, arch="aarch64"):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory)
            scripts = {
                "getconf": f"echo 'glibc {glibc}'" if glibc else "exit 1",
                "ldd": "echo 'musl libc' >&2; exit 1" if musl else "echo unknown; exit 1",
                "uname": f"echo {arch}",
            }
            for name, text in scripts.items():
                path = bin_dir / name
                path.write_text("#!/bin/sh\n" + text + "\n")
                path.chmod(0o755)
            script = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
            return subprocess.run(["sh"], input=script + '\nlinux_arch\nprintf "%s" "$arch"\n',
                                  text=True, capture_output=True,
                                  env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]))

    def test_glibc_baseline(self):
        result = self.select(glibc="2.35")
        self.assertEqual((result.returncode, result.stdout), (0, "arm64"))

    def test_musl_rejected(self):
        result = self.select(musl=True, arch="x86_64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs glibc 2.35 or newer; this system uses musl", result.stderr)

    def test_old_glibc_rejected(self):
        result = self.select(glibc="2.31")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2.35 or newer", result.stderr)

    def test_unknown_rejected(self):
        self.assertNotEqual(self.select().returncode, 0)

    def test_installed_bundle_must_match_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('gft-gui', 'tools/gft', 'install.py', 'SHA256SUMS', *ICON_PATHS):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
                path.chmod(0o755)
            script = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
            script += '\narch=arm64\nsha_check() { return 0; }\nbundle_ok "$BUNDLE"\n'
            for marker, expected in [('linux-x86_64', 1), ('linux-arm64-glibc', 1), ('linux-arm64', 0)]:
                (root / 'PLATFORM').write_text(marker + '\n')
                result = subprocess.run(['sh'], input=script, text=True,
                                        env=dict(os.environ, BUNDLE=directory))
                self.assertEqual(result.returncode, expected, marker)

    def test_latest_version_and_archive_address_come_from_the_release_listing(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            releases, elsewhere = home / "releases", home / "elsewhere"
            write_release(releases, "v0.3.0")
            name = "graffitty-linux-x86_64.tar.gz"
            listing = releases / "v0.3.0.txt"
            checksum = listing.read_text().split()[0]
            # The archive is stored somewhere else, under another name, among
            # other platforms' lines; the listing gives its exact address.
            elsewhere.mkdir()
            (releases / "v0.3.0" / name).rename(elsewhere / "linux-build-3.bin")
            listing.write_text(f"{'a' * 64}  graffitty-macos-arm64.tar.gz  https://example.invalid/mac\r\n"
                               f"{checksum}  {name}  {elsewhere}/linux-build-3.bin\r\n")
            (releases / "latest.txt").write_text("v0.3.0\r\n")
            env = {key: value for key, value in os.environ.items() if not key.startswith(("XDG_", "GRAFFITTY_"))}
            env.update(HOME=str(home), GRAFFITTY_RELEASES=str(releases) + "/", GRAFFITTY_NO_DESKTOP="1",
                       GFT_LOG=str(home / "gft.log"))
            installs = home / ".local/share/graffitty/installs"

            def run(**change):
                return subprocess.run(["sh"], input=install_script(), text=True, capture_output=True,
                                      env=dict(env, **change))

            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.readlink(installs / "current"), "0.3.0")
            self.assertFalse((home / ".local/share/icons").exists())
            for change, message in (
                (dict(GRAFFITTY_VERSION="v9.9.9"), "Graffitty v9.9.9 is not listed at"),
                (dict(GRAFFITTY_RELEASES="releases"), "GRAFFITTY_RELEASES must be an https URL or an absolute directory"),
                (dict(GRAFFITTY_RELEASES="http://example.invalid/releases"), "GRAFFITTY_RELEASES must be an https URL"),
            ):
                result = run(**change)
                self.assertNotEqual(result.returncode, 0, change)
                self.assertIn(message, result.stderr)
            # Nothing installs from a listing that lacks this platform, names it
            # twice, points at a missing file, or gives another file's checksum.
            good = f"{checksum}  {name}  {elsewhere}/linux-build-3.bin\n"
            for text, message in (
                (f"{checksum}  graffitty-macos-arm64.tar.gz  {elsewhere}/linux-build-3.bin\n", f"Graffitty v0.3.0 has no {name}"),
                (good + good, f"Graffitty v0.3.0 lists {name} more than once"),
                (f"{checksum}  {name}  {home}/nowhere.bin\n", f"could not download {name} for release v0.3.0"),
                (f"{'b' * 64}  {name}  {elsewhere}/linux-build-3.bin\n", f"checksum mismatch for {name}"),
                (f"{checksum}  {name}  http://example.invalid/linux.bin\n", "which is not an https address"),
            ):
                listing.write_text(text)
                shutil.rmtree(installs, ignore_errors=True)
                result = run()
                self.assertNotEqual(result.returncode, 0, text)
                self.assertIn(message, result.stderr)
                self.assertFalse((installs / "current").exists(), "nothing was installed")

    def test_reinstall_and_skip_republished_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            releases = home / "releases"
            version = "v0.3.0"
            # A native executable keeps its old mapping after the exchange.
            write_release(releases, version, gui=Path(shutil.which("cat")))
            listing = releases / f"{version}.txt"
            archive = releases / version / "graffitty-linux-x86_64.tar.gz"
            current = home / ".local/share/graffitty/installs/current"
            log = home / "gft.log"
            env = {key: value for key, value in os.environ.items() if not key.startswith(("XDG_", "GRAFFITTY_"))}
            env.update(HOME=str(home), GRAFFITTY_RELEASES=str(releases), GRAFFITTY_VERSION=version,
                       GRAFFITTY_NO_DESKTOP="1", GFT_LOG=str(log))

            def install(skip=False):
                result = subprocess.run(["sh"], input=install_script(), text=True, capture_output=True,
                                        env=dict(env, GRAFFITTY_INSTALL_SKIP_IF_EXISTS=str(int(skip))), timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stderr

            install()
            gui = current / "gft-gui"
            ino = gui.stat().st_ino
            with subprocess.Popen([gui], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as running:
                try:
                    # Even a pristine same-version install must replace the executable.
                    install()
                    self.assertNotEqual(gui.stat().st_ino, ino)
                    output, _ = running.communicate("still running\n", timeout=5)
                    self.assertEqual((running.returncode, output), (0, "still running\n"))
                finally:
                    if running.poll() is None:
                        running.kill()
            (current / "install.py").write_text("local edit")
            install()
            self.assertEqual((current / "install.py").read_text(), "")

            before = gui.stat().st_ino
            calls = log.read_text()
            archive.unlink()  # A skip can read the listing but cannot fetch the archive.
            self.assertIn("archive SHA-256 matches", install(skip=True))
            self.assertEqual(gui.stat().st_ino, before)
            self.assertEqual(log.read_text(), calls)

            # Publish a changed executable under the original release tag.
            shutil.rmtree(releases / version)
            write_release(releases, version)
            self.assertIn("downloading", install(skip=True))
            self.assertEqual(gui.read_text(), "#!/bin/sh\n")
            receipt = current / ".archive-sha256"
            self.assertEqual(receipt.read_text().strip(), listing.read_text().split()[0])
            self.assertIn("internal update finish", log.read_text()[len(calls):])
            receipt.unlink()
            self.assertIn("downloading", install(skip=True))
            self.assertEqual(os.readlink(current), version[1:])
            self.assertEqual(list(current.parent.glob(".staging.*")), [])

    def test_upgrade_finishes_with_the_new_version_and_refreshes_desktop_icons(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            releases = home / "releases"
            script = install_script()
            data = home / "desktop data"
            installs = data / "graffitty/installs"
            cache_tool = home / "gtk-update-icon-cache"
            cache_tool.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$XDG_DATA_HOME/cache-args"\n')
            cache_tool.chmod(0o755)
            log = home / "gft.log"
            first = ["v0.1.0 --version", "v0.1.0 internal update finish"]
            for version, calls in (("v0.1.0", first),
                                   ("v0.2.0", first + ["v0.2.0 --version", "v0.2.0 internal update finish"])):
                write_release(releases, version)
                env = {key: value for key, value in os.environ.items() if not key.startswith(("XDG_", "GRAFFITTY_"))}
                env.update(HOME=str(home), GRAFFITTY_RELEASES=str(releases), GRAFFITTY_VERSION=version,
                           XDG_DATA_HOME=str(data), PATH=str(home) + os.pathsep + os.environ["PATH"],
                           GFT_LOG=str(log))
                result = subprocess.run(["sh"], input=script, text=True, capture_output=True, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(os.readlink(installs / "current"), version[1:])
                for icon in ICON_PATHS:
                    self.assertEqual((data / icon).read_text(), f"{version} {icon}")
                self.assertIn("Icon=graffitty", (data / "applications/Graffitty.desktop").read_text().splitlines())
                self.assertEqual((data / "cache-args").read_text().splitlines(),
                                 ["--force", "--ignore-theme-index", str(data / "icons/hicolor")])
                (data / "cache-args").unlink()
                # install.sh checks that the gft it just installed starts, then runs
                # the finish step with it.
                self.assertEqual(log.read_text().splitlines(), calls)
                self.assertIn("Restarted; 1 terminal(s) kept", result.stderr)
            self.assertTrue((installs / "0.1.0").is_dir(), "the replaced version stays while it may still run")
