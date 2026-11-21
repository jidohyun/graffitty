"""The Windows release archive holds the validated bundle under one folder
and records its checksum beside the other release assets."""

import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "packaging/windows"))
spec = importlib.util.spec_from_file_location(
    "windows_archive", ROOT / "packaging/windows/build_archive.py"
)
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
import build_installer as installer


class WindowsArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "bundle"
        for name in installer.REQUIRED:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"MZfixture")
        (self.bundle / "chromium-host-path.txt").write_text(
            "chromium-windows/graffitty_chromium.exe\n"
        )
        self.output = Path(self.temp.name) / "out"

    def test_archive_holds_the_bundle_under_one_folder(self):
        packed = archive.build(self.bundle, self.output)
        self.assertEqual(packed.name, "graffitty-windows-x64.zip")
        with zipfile.ZipFile(packed) as contents:
            names = set(contents.namelist())
            self.assertEqual(names, {f"Graffitty/{name}" for name in installer.REQUIRED})
            self.assertEqual(contents.read("Graffitty/tools/gft.exe"), b"MZfixture")
        self.assertFalse(packed.with_suffix(".tmp").exists())

    def test_incomplete_bundle_is_not_packed(self):
        (self.bundle / "tools/gft.exe").unlink()
        with self.assertRaisesRegex(ValueError, "Incomplete Windows bundle"):
            archive.build(self.bundle, self.output)
        self.assertFalse((self.output / archive.ASSET).exists())

    def test_checksum_joins_the_other_release_assets(self):
        packed = archive.build(self.bundle, self.output)
        manifest = self.output / "SHA256SUMS"
        other = "a" * 64 + "  graffitty-macos-arm64.tar.gz"
        manifest.write_text(other + "\n")
        installer.write_release_checksum(packed)
        self.assertEqual(manifest.read_text().splitlines(), [
            other, hashlib.sha256(packed.read_bytes()).hexdigest() + "  " + packed.name,
        ])

    def test_install_script_downloads_this_asset_into_this_folder(self):
        script = (ROOT / "packaging/install.ps1").read_text(encoding="ascii")
        self.assertIn(f"$asset = '{archive.ASSET}'", script)
        self.assertIn(f"Join-Path $Staging '{archive.FOLDER}'", script)


if __name__ == "__main__":
    unittest.main()
