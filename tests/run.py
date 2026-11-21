#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1", "websocket-client", "version-pioneer", "markdown-it-py==4.2.0", "psutil"]
# ///
"""Run Python contracts and integrations with private app state and routing.

    uv run tests/run.py [PATTERN] [FOLDER...]

Test folders are not packages: each is discovered with itself as the import
root, so modules import siblings and shared helpers by their plain names.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
# Folders holding Python tests, relative to tests/.
FOLDERS = ("agents", "android", "chromium", "godot", "graph", "platform/linux", "platform/macos",
           "platform/windows", "server", "support", "tools")

DISCOVER = """
import sys, unittest
pattern, folders = sys.argv[1], sys.argv[2:]
loader, suite = unittest.TestLoader(), unittest.TestSuite()
for folder in folders:
    suite.addTests(loader.discover(folder, pattern, top_level_dir=folder))
sys.exit(not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful())
"""

def main():
    pattern = sys.argv[1] if len(sys.argv) > 1 else "test_*.py"
    folders = [str(TESTS / f) for f in (sys.argv[2:] or FOLDERS)]
    # A short root on Unix. Tests start servers in temporary folders; a server
    # keeps its holder sockets beside its descriptor, and a Unix socket path is
    # limited to about 104 bytes, which the default temporary folder of macOS
    # (49 bytes before the test's own folder) leaves too little of.
    short = "/tmp" if os.name == "posix" else None
    with tempfile.TemporaryDirectory(prefix="gft-t-" if short else "graffitty-python-tests-", dir=short) as directory:
        env = {key: value for key, value in os.environ.items()
               if key.startswith("GRAFFITTY_TEST_") or
               not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_SESSION", "CODEX_INTERNAL"))}
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(Path(directory) / kind.lower())
        if short:
            # Every temporary folder a test makes is below this one.
            temporary = Path(directory) / "t"
            temporary.mkdir()
            env["TMPDIR"] = str(temporary)
        return subprocess.call([sys.executable, "-c", DISCOVER, pattern, *folders], cwd=ROOT, env=env)

if __name__ == "__main__":
    raise SystemExit(main())
