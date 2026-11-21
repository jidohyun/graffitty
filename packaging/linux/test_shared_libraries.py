import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from shared_libraries import CHROME_SYSTEM, SYSTEM, dependencies, needed


class DependencyTests(unittest.TestCase):
    def test_system_boundaries(self):
        for name in ("libc.so.6", "libm.so.6", "libGLX.so.0", "libvulkan.so.1",
                     "libX11.so.6", "libwayland-client.so.0", "ld-linux-aarch64.so.1",
                     "libstdc++.so.6", "libgcc_s.so.1"):
            self.assertIsNotNone(SYSTEM.fullmatch(name), name)
        for name in ("libssl.so.3", "libcef.so", "ld-musl-aarch64.so.1"):
            self.assertIsNone(SYSTEM.fullmatch(name), name)

    def test_chromium_takes_chromes_usual_libraries_from_the_system(self):
        for name in ("libnss3.so", "libnspr4.so", "libsmime3.so", "libglib-2.0.so.0", "libgio-2.0.so.0",
                     "libatk-bridge-2.0.so.0", "libcups.so.2", "libpango-1.0.so.0", "libcairo.so.2", "libasound.so.2"):
            self.assertIsNotNone(CHROME_SYSTEM.fullmatch(name), name)
        for name in ("libstdc++.so.6", "libcef.so", "libvk_swiftshader.so", "libEGL.so"):
            self.assertIsNone(CHROME_SYSTEM.fullmatch(name), name)

    @patch("shared_libraries.subprocess.check_output")
    def test_needed_reads_only_direct_dependencies(self, check_output):
        check_output.return_value = (
            " 0x0000000000000001 (NEEDED)             Shared library: [libcef.so]\n"
            " 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]\n"
            " 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]\n")
        self.assertEqual(needed(Path("graffitty_chromium")), ["libcef.so", "libstdc++.so.6"])

    @patch("shared_libraries.subprocess.run")
    def test_parse(self, run):
        run.return_value = subprocess.CompletedProcess([], 0,
            "linux-vdso.so.1 (0x123)\n libstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x456)\n", "")
        self.assertEqual(dependencies(Path("app")),
                         [("libstdc++.so.6", Path("/usr/lib/libstdc++.so.6"))])

    @patch("shared_libraries.subprocess.run")
    def test_dependency_path_with_spaces(self, run):
        run.return_value = subprocess.CompletedProcess([], 0,
            " libprivate.so => /tmp/build with spaces/libprivate.so (0x456)\n", "")
        self.assertEqual(dependencies(Path("app")),
                         [("libprivate.so", Path("/tmp/build with spaces/libprivate.so"))])

    @patch("shared_libraries.subprocess.run")
    def test_missing_rejected(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, "libfoo.so => not found\n", "")
        with self.assertRaises(RuntimeError):
            dependencies(Path("app"))


if __name__ == "__main__":
    unittest.main()
