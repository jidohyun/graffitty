"""Cached CEF binaries must represent the current capture sources before shipping."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "cef_installer", ROOT / "apps/server/chromium/install_framework.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class FrameworkTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.sources = root / "source"
        self.sources.mkdir()
        for name in installer.RECIPE.INPUTS:
            (self.sources / name).write_text("captured build input: " + name)
        source_patch = patch.object(installer.RECIPE, "HERE", self.sources)
        source_patch.start()
        self.addCleanup(source_patch.stop)
        self.archive = root / "framework.tar.zst"
        self.archive.write_bytes(b"built framework archive")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (root / "SHA256SUMS").write_text(f"{self.digest}  {self.archive.name}\n")
        self.provenance = root / "provenance.json"
        self.record = dict(pins=installer.RECIPE.PINS, archive_sha256=self.digest,
                           inputs_sha256=installer.RECIPE.input_hashes())
        self.write_provenance()
        self.app = root / "host.app"
        (self.app / "Contents/Frameworks" / installer.NAME).mkdir(parents=True)
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "custom-cef-source.txt").write_text(f"sha256={self.digest}\n")

    def write_provenance(self):
        self.provenance.write_text(json.dumps(self.record))

    def check_installed(self):
        with patch.object(installer, "ARCHIVE", self.archive), patch.object(
            sys, "argv", ["install_framework.py", "--check", str(self.app)]
        ):
            installer.main()

    def test_matching_release_and_installed_marker(self):
        self.assertEqual(installer.verify(self.archive), self.digest)
        with self.assertRaises(SystemExit) as exit:
            self.check_installed()
        self.assertEqual(exit.exception.code, 0)

    def test_source_fix_rejects_old_release_even_with_matching_installed_marker(self):
        (self.sources / "chrome_gpu_capture.cc").write_text("capture now allows sleep")
        with self.assertRaisesRegex(SystemExit, "CEF archive is stale"):
            installer.verify(self.archive)
        with self.assertRaisesRegex(SystemExit, "CEF archive is stale"):
            self.check_installed()

    def test_incomplete_or_wrong_revision_provenance_is_rejected(self):
        del self.record["inputs_sha256"]["chromium.patch"]
        self.write_provenance()
        with self.assertRaisesRegex(SystemExit, "CEF archive is stale"):
            installer.verify(self.archive)
        self.record["inputs_sha256"] = installer.RECIPE.input_hashes()
        self.record["pins"] = {}
        self.write_provenance()
        with self.assertRaisesRegex(SystemExit, "CEF archive is stale"):
            installer.verify(self.archive)

    def test_provenance_belongs_to_this_archive_and_archive_is_intact(self):
        self.record["archive_sha256"] = "0" * 64
        self.write_provenance()
        with self.assertRaisesRegex(SystemExit, "does not match the release archive"):
            installer.verify(self.archive)
        self.record["archive_sha256"] = self.digest
        self.write_provenance()
        self.archive.write_bytes(b"corrupt archive")
        with self.assertRaisesRegex(SystemExit, "SHA-256 mismatch"):
            installer.verify(self.archive)

    def test_missing_or_invalid_provenance_is_rejected(self):
        self.provenance.unlink()
        with self.assertRaisesRegex(SystemExit, "Missing or invalid CEF provenance"):
            installer.verify(self.archive)
        self.provenance.write_text("{")
        with self.assertRaisesRegex(SystemExit, "Missing or invalid CEF provenance"):
            installer.verify(self.archive)


if __name__ == "__main__":
    unittest.main()
