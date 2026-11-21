#!/usr/bin/env python3
"""Exercise canonical patches against pristine pinned files, without a new checkout."""

import argparse
import importlib.util
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("cef_recipe", ROOT / "fork/cef/build.py")
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


def pristine(real_tree, target, patch_file):
    target.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    summary = subprocess.check_output(
        ["git", "apply", "--numstat", str(patch_file)], text=True
    )
    for row in summary.splitlines():
        name = row.split("\t", 2)[2]
        original = subprocess.check_output(
            ["git", "-C", str(real_tree), "show", "HEAD:" + name]
        )
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(original)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-root", required=True, type=Path)
    args = parser.parse_args()
    work = args.work_root.resolve()
    recipe.verify(work)  # Real revisions, not mocked.
    src, cef = recipe.trees(work)
    with tempfile.TemporaryDirectory(prefix="cef-recipe-test-") as directory:
        isolated = Path(directory)
        fixture_src, fixture_cef = recipe.trees(isolated)
        for tree, fixture, names in (
            (src, fixture_src, ("chromium.patch", "session_lifetime.patch")),
            (cef, fixture_cef, ("cef.patch", "native_tabs.patch")),
        ):
            for name in names:
                pristine(tree, fixture, recipe.HERE / name)
        guard = fixture_cef / "libcef/browser" / recipe.SOURCES[0]
        guard.parent.mkdir(parents=True, exist_ok=True)
        guard.write_text("unrelated developer changes\n")
        before = (fixture_cef / "BUILD.gn").read_bytes()
        # Tiny fixture repositories do not have the full pinned commit graph.
        # Only bypass revision checks here; actual git patch application runs.
        with patch.object(recipe, "check_revisions"):
            try:
                recipe.apply(isolated)
            except SystemExit:
                pass
            else:
                raise AssertionError("Conflicting source was not rejected")
            assert (fixture_cef / "BUILD.gn").read_bytes() == before
            assert guard.read_text() == "unrelated developer changes\n"
            guard.unlink()
            recipe.apply(isolated)
            recipe.apply(isolated)  # Already applied: no duplicate hooks.
            recipe.apply(isolated, verify_only=True)
        print("PASS pristine patch application, idempotence and conflict preflight")
        try:
            recipe.bootstrap(isolated)
        except SystemExit:
            pass
        else:
            raise AssertionError("Bootstrap accepted an existing directory")
        with patch.object(recipe, "revision", return_value="wrong-revision"):
            try:
                recipe.check_revisions(isolated)
            except SystemExit:
                pass
            else:
                raise AssertionError("Mismatched revision was accepted")
        print("PASS existing-directory and revision guards")
    print("CEF_RECIPE_SMOKE_PASS (not a full cold bootstrap/build)")


if __name__ == "__main__":
    main()
