"""Run with uv run --with version-pioneer==0.0.16 python tests/tools/test_build_info.py."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "tools/build_info.py"
spec = importlib.util.spec_from_file_location("build_info", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionTests(unittest.TestCase):
    def test_tag_commit_and_dirty_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(root), *args], text=True
                ).strip()

            git("init", "-q")
            git("config", "user.name", "Version Test")
            git("config", "user.email", "version@example.invalid")
            source = root / "source.txt"
            source.write_text("one")
            git("add", ".")
            git("commit", "-qm", "Initial")
            git("tag", "v1.2.3")
            subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root)], check=True
            )
            tagged = json.loads((root / "frontends/godot/project/graffitty/build-info.json").read_text())
            self.assertEqual(tagged["version"], "1.2.3")
            self.assertEqual(tagged["full_revisionid"], git("rev-parse", "HEAD"))
            cargo = subprocess.check_output(
                [sys.executable, str(SCRIPT), "--root", str(root), "--cargo"], text=True
            )
            self.assertIn("cargo:rustc-env=GRAFFITTY_VERSION=1.2.3\n", cargo)
            self.assertNotIn("cargo:rerun-if-changed=" + str(source), cargo)
            self.assertIn("cargo:rerun-if-changed=" + str(root / ".git/HEAD"), cargo)
            # Identical builds leave the frozen metadata's mtime unchanged.
            stamp = (root / "frontends/godot/project/graffitty/build-info.json").stat().st_mtime_ns
            subprocess.run([sys.executable, str(SCRIPT), "--root", str(root), "--cargo"], check=True, capture_output=True)
            self.assertEqual((root / "frontends/godot/project/graffitty/build-info.json").stat().st_mtime_ns, stamp)

            source.write_text("two")
            self.assertTrue(module.get_version_dict_wo_exec(cwd=root)["dirty"])
            git("commit", "-qam", "Next")
            version = module.get_version_dict_wo_exec(cwd=root)["version"]
            self.assertTrue(version.startswith("1.2.3+1.g"), version)
            # Linked worktrees store .git as a file; Cargo must watch real refs.
            checkout = root / "worktree"
            git("worktree", "add", "--detach", str(checkout), "HEAD")
            cargo = subprocess.check_output(
                [sys.executable, str(SCRIPT), "--root", str(checkout), "--cargo"], text=True
            )
            self.assertIn("cargo:rustc-env=GRAFFITTY_VERSION=" + version, cargo)
            self.assertIn(str(root / ".git/worktrees/worktree/HEAD"), cargo)
            source.unlink()
            cargo = subprocess.check_output(
                [sys.executable, str(SCRIPT), "--root", str(root), "--cargo"], text=True
            )
            self.assertNotIn("cargo:rerun-if-changed=" + str(source), cargo)
            watched = [line.split("=", 1)[1] for line in cargo.splitlines()
                       if line.startswith("cargo:rerun-if-changed=")]
            self.assertTrue(all(Path(path).exists() for path in watched), watched)

    def test_source_archive_uses_frozen_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            target = root / "frontends/godot/project/graffitty/build-info.json"
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps({"version": "2.3.4", "error": None}) + "\n")
            output = subprocess.check_output(
                [sys.executable, str(SCRIPT), "--root", str(root), "--cargo"], text=True
            )
            self.assertIn("cargo:rustc-env=GRAFFITTY_VERSION=2.3.4", output)

    def test_an_explicit_version_replaces_the_git_one(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()

            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

            git("init", "-q")
            git("config", "user.name", "Version Test")
            git("config", "user.email", "version@example.invalid")
            (root / "source.txt").write_text("one")
            git("add", ".")
            git("commit", "-qm", "Initial")
            (root / "source.txt").write_text("two")
            env = dict(os.environ, GRAFFITTY_BUILD_VERSION="0.0.1")
            cargo = subprocess.check_output(
                [sys.executable, str(SCRIPT), "--root", str(root), "--cargo"], text=True, env=env
            )
            self.assertIn("cargo:rustc-env=GRAFFITTY_VERSION=0.0.1\n", cargo)
            self.assertIn("cargo:rerun-if-env-changed=GRAFFITTY_BUILD_VERSION\n", cargo)
            frozen = json.loads((root / "frontends/godot/project/graffitty/build-info.json").read_text())
            # Untagged and dirty, yet the version is the named one; Git's facts stay.
            self.assertEqual(frozen["version"], "0.0.1")
            self.assertEqual(frozen["full_revisionid"], git("rev-parse", "HEAD"))
            self.assertTrue(frozen["dirty"])
            # Without Git or a frozen file, the name alone is enough.
            bare = root / "bare"
            bare.mkdir()
            subprocess.run([sys.executable, str(SCRIPT), "--root", str(bare)], check=True, env=env, capture_output=True)
            self.assertEqual(json.loads((bare / "frontends/godot/project/graffitty/build-info.json").read_text())["version"], "0.0.1")
            rejected = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root)], env=dict(env, GRAFFITTY_BUILD_VERSION="v0.0.1"),
                capture_output=True, text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("must look like 1.2.3", rejected.stderr)



if __name__ == "__main__":
    unittest.main()
