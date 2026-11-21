"""Reject incomplete or private installer payloads before invoking Inno Setup."""

import importlib.util
import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    "windows_installer", ROOT / "packaging/windows/build_installer.py"
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class WindowsInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name)
        for name in installer.REQUIRED:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"MZfixture")
        (self.bundle / "chromium-host-path.txt").write_text(
            "chromium-windows/graffitty_chromium.exe\n"
        )

    def test_release_checksum_preserves_other_assets_and_replaces_own_entry(self):
        setup = self.bundle / "Graffitty-1.2.3-windows-x64-setup.exe"
        setup.write_bytes(b"first installer")
        manifest = self.bundle / "SHA256SUMS"
        other = "a" * 64 + "  graffitty-linux-arm64.tar.gz"
        manifest.write_text(other + "\n")
        self.assertEqual(installer.write_release_checksum(setup), manifest)
        setup.write_bytes(b"updated installer")
        installer.write_release_checksum(setup)
        self.assertEqual(manifest.read_text().splitlines(), [
            other, hashlib.sha256(b"updated installer").hexdigest() + "  " + setup.name,
        ])
        self.assertFalse(manifest.with_suffix(".tmp").exists())

    def test_release_checksum_creates_manifest(self):
        setup = self.bundle / "Graffitty-1.2.3-windows-x64-setup.exe"
        setup.write_bytes(b"installer")
        manifest = installer.write_release_checksum(setup)
        self.assertEqual(manifest.read_text(),
                         hashlib.sha256(b"installer").hexdigest() + "  " + setup.name + "\n")

    def test_setup_removes_the_external_ui_pack_and_archive_receipt(self):
        script = (ROOT / "packaging/windows/graffitty.iss").read_text(encoding="utf-8")
        section = script.split("[InstallDelete]\n", 1)[1].split("\n[", 1)[0]
        self.assertIn('Type: files; Name: "{app}\\Graffitty.pck"', section)
        self.assertIn('Type: files; Name: "{app}\\.archive-sha256"', section)
        self.assertNotIn("filesandordirs", section)

    def test_complete_bundle(self):
        installer.validate_bundle(self.bundle)

    def test_missing_native_dependency(self):
        (self.bundle / "tools/gft.exe").unlink()
        with self.assertRaisesRegex(ValueError, "Incomplete Windows bundle"):
            installer.validate_bundle(self.bundle)

    def test_missing_chromium_bootstrap_module(self):
        (self.bundle / "chromium-windows/graffitty_chromium.dll").unlink()
        with self.assertRaisesRegex(ValueError, "graffitty_chromium.dll"):
            installer.validate_bundle(self.bundle)

    def test_external_world_directory_is_rejected(self):
        (self.bundle / "worlds").mkdir()
        with self.assertRaisesRegex(ValueError, "External worlds"):
            installer.validate_bundle(self.bundle)

    def test_external_world_pack_is_rejected(self):
        (self.bundle / "bistro.pck").write_bytes(b"GDPC")
        with self.assertRaisesRegex(ValueError, "External worlds"):
            installer.validate_bundle(self.bundle)

    def test_missing_sideloaded_conpty(self):
        (self.bundle / "tools/OpenConsole.exe").unlink()
        with self.assertRaisesRegex(ValueError, "tools/OpenConsole.exe"):
            installer.validate_bundle(self.bundle)

    def test_private_runtime_state(self):
        (self.bundle / "auth.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "private file"):
            installer.validate_bundle(self.bundle)

    def test_host_cannot_escape_bundle(self):
        (self.bundle / "chromium-host-path.txt").write_text("../../host.exe")
        with self.assertRaisesRegex(ValueError, "relative"):
            installer.validate_bundle(self.bundle)

    def test_wrong_platform_binary(self):
        (self.bundle / "tools/gft.exe").write_bytes(b"\x7fELF")
        with self.assertRaisesRegex(ValueError, "Not a Windows executable"):
            installer.validate_bundle(self.bundle)

    def test_installer_languages_match_the_app(self):
        script = (ROOT / "packaging/windows/graffitty.iss").read_text(encoding="utf-8")
        names = re.findall(r'^Name: "(\w+)"; MessagesFile:', script, re.M)
        locales = {
            "english": "en-US", "french": "fr", "brazilianportuguese": "pt-BR",
            "spanish": "es", "italian": "it", "korean": "ko", "japanese": "ja",
            "german": "de", "norwegian": "nb", "swedish": "sv", "danish": "da",
        }
        catalog = json.loads(
            (ROOT / "frontends/godot/project/config/localization.json").read_text(encoding="utf-8")
        )
        self.assertEqual([locales.get(name, name) for name in names], list(catalog["locales"]))
        for name in names:
            self.assertRegex(script, rf"(?m)^{name}\.CreateStartMenuIcon=\S")


if __name__ == "__main__":
    unittest.main()
