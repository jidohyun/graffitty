#!/usr/bin/env python3
"""Compile a per-user Windows installer from an exported Graffitty bundle."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = (
    "Graffitty.exe",
    "GraffittyRuntime.exe",
    "tools/gft.exe",
    "tools/gft-gui.cmd",
    "tools/conpty.dll",
    "tools/OpenConsole.exe",
    "licenses/conpty-LICENSE.txt",
    "licenses/FFmpeg-COPYING.LGPLv2.1",
    "libgraffitty.windows.x86_64.dll",
    "chromium-windows/graffitty_chromium.exe",
    "chromium-windows/graffitty_chromium.dll",
    "chromium-windows/libcef.dll",
    "chromium-windows/icudtl.dat",
    "chromium-host-path.txt",
)


def validate_bundle(bundle: Path) -> None:
    missing = [name for name in REQUIRED if not (bundle / name).is_file()]
    if missing:
        raise ValueError("Incomplete Windows bundle: " + ", ".join(missing))
    if (
        bundle / "chromium-host-path.txt"
    ).read_text().strip() != "chromium-windows/graffitty_chromium.exe":
        raise ValueError(
            "Chromium host pointer must be relative to the installed bundle"
        )
    for name in REQUIRED:
        path = bundle / name
        if path.suffix in (".exe", ".dll"):
            with path.open("rb") as file:
                if file.read(2) != b"MZ":
                    raise ValueError(f"Not a Windows executable: {name}")
    for path in bundle.rglob("*"):
        if path.name == "worlds" or path.suffix == ".pck":
            raise ValueError(f"External worlds must not be bundled: {path}")
        if path.is_symlink():
            raise ValueError(f"Installer payload must not contain symlinks: {path}")
        if path.name in {
            ".git",
            ".dvc",
            "target",
            "node_modules",
            "project.godot",
            "auth.json",
            "remote-auth.json",  # Old private files must not enter installer payloads.
            "server.json",
        }:
            raise ValueError(
                f"Unexpected development or private file in payload: {path}"
            )


def find_compiler() -> str:
    if compiler := shutil.which("ISCC.exe"):
        return compiler
    for variable, suffix in (
        ("LOCALAPPDATA", "Programs/Inno Setup 6/ISCC.exe"),
        ("ProgramFiles(x86)", "Inno Setup 6/ISCC.exe"),
        ("ProgramFiles", "Inno Setup 6/ISCC.exe"),
    ):
        if base := os.environ.get(variable):
            candidate = Path(base) / suffix
            if candidate.is_file():
                return str(candidate)
    raise FileNotFoundError("Install Inno Setup 6 or pass --iscc /path/to/ISCC.exe")


def write_release_checksum(installer: Path) -> Path:
    """Update this asset's entry while retaining other release assets."""
    manifest = installer.parent / "SHA256SUMS"
    with installer.open("rb") as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    lines = manifest.read_text().splitlines() if manifest.exists() else []
    lines = [line for line in lines
             if not (len(line.split()) == 2
                     and line.split()[1].removeprefix("*").removeprefix("./") == installer.name)]
    lines.append(f"{digest.hexdigest()}  {installer.name}")
    temporary = manifest.with_suffix(".tmp")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / "dist/windows")
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/installers")
    parser.add_argument("--iscc")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[.-][A-Za-z0-9.-]+)?", args.version):
        parser.error("--version must be a filename-safe version such as 0.1.0")
    bundle = args.bundle.resolve()
    validate_bundle(bundle)
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            args.iscc or find_compiler(),
            f"/DPayloadDir={bundle}",
            f"/DAppVersion={args.version}",
            f"/DOutputDir={args.output.resolve()}",
            str(Path(__file__).with_name("graffitty.iss")),
        ],
        check=True,
    )
    installer = args.output / f"Graffitty-{args.version}-windows-x64-setup.exe"
    if not installer.is_file():
        raise RuntimeError(
            "Compiler returned successfully without producing the installer"
        )
    print(installer)
    print(write_release_checksum(installer))


if __name__ == "__main__":
    main()
