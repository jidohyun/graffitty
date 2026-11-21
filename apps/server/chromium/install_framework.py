#!/usr/bin/env python3
"""Install the patched CEF framework into the built host bundle.

Run dvc pull assets.dvc if the framework is missing. The build lives
under assets/ and includes Graffitty's Chrome-style GPU capture patch.
See fork/cef/artifacts/macos-arm64/framework/README.md for provenance.
"""

import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
VENDOR = ROOT / "fork/cef/artifacts/macos-arm64/framework"
ARCHIVE = VENDOR / "Chromium-Embedded-Framework.framework.tar.zst"
NAME = "Chromium Embedded Framework.framework"
_spec = importlib.util.spec_from_file_location("graffitty_cef_recipe", ROOT / "fork/cef/build.py")
RECIPE = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RECIPE)


def verify_source(archive: pathlib.Path, expected: str) -> None:
    try:
        provenance = json.loads((archive.parent / "provenance.json").read_text())
    except (OSError, ValueError) as error:
        raise SystemExit(f"Missing or invalid CEF provenance: {error}") from error
    if not isinstance(provenance, dict) or provenance.get("archive_sha256") != expected:
        raise SystemExit("CEF provenance does not match the release archive")
    if provenance.get("pins") != RECIPE.PINS or provenance.get("inputs_sha256") != RECIPE.input_hashes():
        raise SystemExit(
            "CEF archive is stale: rebuild and package fork/cef, then promote the archive, "
            "provenance.json and SHA256SUMS together before building the host"
        )


def expected_digest(archive: pathlib.Path) -> str:
    sums = archive.parent / "SHA256SUMS"
    expected = next(
        (
            line.split()[0]
            for line in sums.read_text().splitlines()
            if line.rstrip().endswith("  " + archive.name)
        ),
        None,
    )
    if expected is None:
        raise SystemExit("No SHA-256 recorded for %s in %s" % (archive.name, sums))
    verify_source(archive, expected)
    return expected


def verify(archive: pathlib.Path) -> str:
    expected = expected_digest(archive)
    digest = hashlib.sha256()
    with archive.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit(
            "SHA-256 mismatch for %s; refusing to install a corrupt framework" % archive
        )
    return expected


def main() -> None:
    if sys.argv[1:] == ["--verify"]:
        verify(ARCHIVE)
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        app = pathlib.Path(sys.argv[2]).resolve()
        marker = app / "Contents/Resources/custom-cef-source.txt"
        current = (app / "Contents/Frameworks" / NAME).is_dir() and marker.is_file()
        current = (
            current
            and ("sha256=" + expected_digest(ARCHIVE))
            in marker.read_text().splitlines()
        )
        raise SystemExit(0 if current else 1)
    if len(sys.argv) != 2:
        raise SystemExit("usage: install_framework.py --verify | [--check] <path to .app>")
    app = pathlib.Path(sys.argv[1]).resolve()
    if not (app / "Contents/Frameworks").is_dir():
        raise SystemExit("Not an app bundle: %s" % app)
    if not ARCHIVE.exists():
        raise SystemExit(
            "Missing %s; run `dvc pull assets.dvc`" % ARCHIVE.relative_to(ROOT)
        )
    digest = verify(ARCHIVE)
    target = app / "Contents/Frameworks" / NAME
    with tempfile.TemporaryDirectory(prefix="cef-framework-") as tmp:
        # macOS tar (libarchive) decompresses .tar.zst directly.
        #
        # Do not pipe `zstd -dc` into it: bsdtar stops at the end-of-archive
        # marker without draining the trailing padding, so zstd takes EPIPE
        # and exits non-zero even though extraction succeeded.
        try:
            subprocess.run(["tar", "-xf", str(ARCHIVE), "-C", tmp], check=True)
        except subprocess.CalledProcessError:
            # Fall back for a tar without zstd support.
            staged = pathlib.Path(tmp) / "framework.tar"
            with staged.open("wb") as out:
                subprocess.run(["zstd", "-dc", str(ARCHIVE)], stdout=out, check=True)
            subprocess.run(["tar", "-xf", str(staged), "-C", tmp], check=True)
            staged.unlink()
        extracted = pathlib.Path(tmp) / NAME
        if not (extracted / "Versions/A/Chromium Embedded Framework").is_file():
            raise SystemExit("Archive did not contain a complete CEF framework")
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(extracted, target, symlinks=True)
    (app / "Contents/Resources/custom-cef-source.txt").write_text(
        str(ARCHIVE.relative_to(ROOT)) + "\nsha256=" + digest + "\n"
    )
    print(target)


if __name__ == "__main__":
    main()
