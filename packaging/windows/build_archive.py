#!/usr/bin/env python3
"""Pack an exported Graffitty Windows bundle into the release archive that
packaging/install.ps1 downloads and unpacks."""

import argparse
from pathlib import Path
import zipfile

from build_installer import ROOT, validate_bundle, write_release_checksum

ASSET = "graffitty-windows-x64.zip"
# install.ps1 expects every file under this folder.
FOLDER = "Graffitty"


def build(bundle: Path, output: Path) -> Path:
    validate_bundle(bundle)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ASSET
    temporary = archive.with_suffix(".tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as packed:
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                packed.write(path, f"{FOLDER}/{path.relative_to(bundle).as_posix()}")
    temporary.replace(archive)
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / "dist/windows")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/installers")
    args = parser.parse_args()
    archive = build(args.bundle.resolve(), args.output.resolve())
    print(archive)
    print(write_release_checksum(archive))


if __name__ == "__main__":
    main()
