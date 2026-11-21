# /// script
# requires-python = ">=3.10"
# dependencies = ["version-pioneer==0.0.16"]
# ///
"""Freeze the application version: uv run tools/build_info.py.

The version comes from Git tags, unless GRAFFITTY_BUILD_VERSION names it.
"""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path

from version_pioneer.api import get_version_dict_wo_exec

ROOT = Path(__file__).resolve().parents[1]
EXPLICIT = "GRAFFITTY_BUILD_VERSION"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--cargo", action="store_true", help="Emit Cargo build-script directives")
    args = parser.parse_args()
    root = args.root.resolve()
    target = root / "frontends/godot/project/graffitty/build-info.json"
    if not (root / ".git").exists() and target.exists():
        version = json.loads(target.read_text(encoding="utf-8"))
    elif not (root / ".git").exists() and os.environ.get(EXPLICIT) is not None:
        version = {"version": None, "full_revisionid": None, "dirty": None, "error": None, "date": None}
    else:
        version = get_version_dict_wo_exec(cwd=root, tag_prefix="v")
    if version.get("error"):
        raise SystemExit(version["error"])
    # A release names its version itself: it must not depend on where the tag
    # is, or on unrelated uncommitted files. Revision and dirty state stay as
    # Git reports them, for bug reports.
    explicit = os.environ.get(EXPLICIT)
    if explicit is not None:
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", explicit):
            raise SystemExit(f"{EXPLICIT} must look like 1.2.3, not {explicit!r}")
        version["version"] = explicit
    target.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(version, indent=2) + "\n"
    if not target.exists() or target.read_text(encoding="utf-8") != content:
        target.write_text(content, encoding="utf-8")
    if args.cargo:
        print("cargo:rustc-env=GRAFFITTY_VERSION=" + version["version"])
        print("cargo:rerun-if-env-changed=" + EXPLICIT)
        print("cargo:rerun-if-changed=" + str(Path(__file__).resolve()))
        print("cargo:rerun-if-changed=" + str(target))
        if (root / ".git").exists():
            # mise refreshes the frozen version before building. Watch that
            # result and Git identity, rather than recompiling native binaries
            # after every world, UI, documentation, or test edit.
            for name in ["HEAD", "index", "refs", "packed-refs"]:
                path = subprocess.check_output(
                    ["git", "rev-parse", "--path-format=absolute", "--git-path", name], cwd=root, text=True
                ).strip()
                # A nonexistent packed-refs file would invalidate every build.
                if Path(path).exists():
                    print("cargo:rerun-if-changed=" + path)
    else:
        print("Graffitty " + version["version"])


if __name__ == "__main__":
    main()
