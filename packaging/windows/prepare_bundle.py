#!/usr/bin/env python3
"""Export the Windows desktop and stage its native runtime dependencies."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from mise_tasks import godot  # noqa: E402
from check_godot import failed as godot_failed  # noqa: E402

# Windows' inbox ConPTY re-renders output and drops what it does not handle,
# such as OSC 10/11 color queries and mouse-mode requests.
#
# ConPTY 1.22+ passes the VT stream through. portable-pty loads conpty.dll
# from the server executable's directory, and conpty.dll starts the
# OpenConsole.exe beside it.
CONPTY_VERSION = "1.25.260930003"
CONPTY_SHA256 = "02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee"


def copy_runtime(source: Path, destination: Path) -> None:
    def ignore(directory, names):
        return [
            name
            for name in names
            if name in {".godot", ".git", "__pycache__"}
            or (Path(directory) / name / ".gdignore").is_file()
        ]

    shutil.copytree(source, destination, ignore=ignore)


def stage_conpty(destination: Path) -> None:
    cache = ROOT / ".cache/conpty"
    package = cache / f"microsoft.windows.console.conpty.{CONPTY_VERSION}.nupkg"
    if not package.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        url = (
            "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/"
            f"{CONPTY_VERSION}/{package.name}"
        )
        with urllib.request.urlopen(url) as source:
            package.write_bytes(source.read())
    if hashlib.sha256(package.read_bytes()).hexdigest() != CONPTY_SHA256:
        package.unlink()  # Let the next run download it again.
        raise RuntimeError("ConPTY package checksum mismatch")
    with zipfile.ZipFile(package) as archive:
        for member in (
            "runtimes/win-x64/native/conpty.dll",
            "build/native/runtimes/x64/OpenConsole.exe",
        ):
            (destination / Path(member).name).write_bytes(archive.read(member))


def run_godot(launch: str, *args) -> None:
    result = subprocess.run(
        [launch, *map(str, args)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    print(result.stdout, end="")
    if godot_failed(result.returncode, result.stdout):
        raise RuntimeError("Godot export failed; see the engine errors above")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    launch = args.godot or godot()
    source = ROOT / "frontends/godot/project"
    chromium = ROOT / "dist/chromium-windows"
    for path in [
        source / "addons/graffitty/bin/libgraffitty.windows.x86_64.dll",
        ROOT / "dist/bin/gft.exe",
        ROOT / "dist/bin/gft-gui.cmd",
        chromium / "graffitty_chromium.exe",
        chromium / "graffitty_chromium.dll",
        chromium / "libcef.dll",
        ROOT / "dist/filetree/manifest.json",
    ]:
        if not path.is_file():
            raise FileNotFoundError(
                f"Build the Windows native dependencies first: {path}"
            )
    if json.loads((ROOT / "dist/filetree/manifest.json").read_text())["platform"] != "windows-x86_64":
        raise RuntimeError("Build dist/filetree for windows-x86_64 with tools/build_filetree_runtime.py")
    stage = ROOT / "build/windows-installer/project"
    output = ROOT / "dist/windows"
    # Both directories are generated outputs owned by this packaging task.
    for directory in (stage, output):
        if directory.exists():
            for child in directory.iterdir():
                if directory == stage and child.name == ".godot":
                    continue  # Import cache is keyed by the current source files.
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        directory.mkdir(parents=True, exist_ok=True)
    for directory in (
        "scenes",
        "config",
        "presets",
        "mods",
        "graffitty",
        "assets/icons",
        "assets/branding/exports",
        "addons/source_assets",
    ):
        copy_runtime(source / directory, stage / directory)
    native = stage / "addons/graffitty/bin"
    native.mkdir(parents=True)
    shutil.copy2(source / "addons/graffitty/bin/libgraffitty.windows.x86_64.dll", native)
    shutil.copy2(source / "addons/graffitty/graffitty.gdextension", native.parent)
    project = (source / "project.godot").read_text()
    (stage / "project.godot").write_text(project)
    shutil.copy2(Path(__file__).with_name("export_presets.cfg"), stage)
    run_godot(launch, "--headless", "--editor", "--path", stage, "--import")
    run_godot(
        launch,
        "--headless",
        "--path",
        stage,
        "--export-release",
        "Windows",
        output / "GraffittyRuntime.exe",
    )
    # Build a GUI-subsystem entry point. Embed the same icon as the engine so
    # existing Start menu, taskbar and Explorer registrations keep their icon.
    kits = Path(os.environ["ProgramFiles(x86)"]) / "Windows Kits/10/bin"
    rc = shutil.which("rc.exe") or max(kits.glob("*/x64/rc.exe"))
    icon = (stage / "assets/branding/exports/graffitty.ico").as_posix()
    resource = stage / "launcher.rc"
    resource.write_text(f'1 ICON "{icon}"\n', encoding="utf-16")
    subprocess.run([str(rc), "/nologo", "/fo", str(resource.with_suffix(".res")), str(resource)], check=True)
    subprocess.run(["rustc", str(Path(__file__).with_name("gui.rs")), "-C",
                    f"link-arg={resource.with_suffix('.res')}", "-o", str(output / "Graffitty.exe")], check=True)
    tools = output / "tools"
    tools.mkdir()
    for name in ("gft.exe", "gft-gui.cmd"):
        shutil.copy2(ROOT / "dist/bin" / name, tools)
    stage_conpty(tools)
    shutil.copy2(ROOT / "tools/install_shell_integration.py", tools)
    shutil.copy2(Path(__file__).with_name("install-context-menu.ps1"), output)
    copy_runtime(ROOT / "apps/server/shell-integration", tools / "shell-integration")
    copy_runtime(ROOT / "skills/terminal-chromium", output / "skills/terminal-chromium")
    copy_runtime(ROOT / "skills/graffitty", output / "skills/graffitty")
    copy_runtime(chromium, output / "chromium-windows")
    # Read-only bundled filetree (tools/build_filetree_runtime.py), found beside tools\gft.exe.
    copy_runtime(ROOT / "dist/filetree", output / "filetree")
    subprocess.run([
        "icacls", str(output / "chromium-windows"),
        "/grant", "*S-1-15-2-2:(OI)(CI)(RX)", "/T", "/Q",
    ], check=True)
    (output / "chromium-host-path.txt").write_text(
        "chromium-windows/graffitty_chromium.exe\n"
    )
    licenses = output / "licenses"
    licenses.mkdir()
    for path, name in (
        (ROOT / "LICENSE", "Graffitty-LICENSE.txt"),
        (ROOT / "NOTICE", "Graffitty-NOTICE.txt"),
        (ROOT / "frontends/godot/extension/fonts/OFL.txt", "bundled-fonts-OFL.txt"),
        (ROOT / "licenses/godotty-MIT.txt", "godotty-LICENSE.txt"),
        (ROOT / "fork/portable-pty/LICENSE.md", "portable-pty-LICENSE.txt"),
        (ROOT / "licenses/microsoft-terminal-MIT.txt", "conpty-LICENSE.txt"),
        (ROOT / ".cache/chromium-video/x86_64-pc-windows-msvc/COPYING.LGPLv2.1", "FFmpeg-COPYING.LGPLv2.1"),
    ):
        shutil.copy2(path, licenses / name)
    for path in sorted((output / "filetree/licenses").iterdir()):
        shutil.copy2(path, licenses / ("filetree-" + path.name))
    print(output)


if __name__ == "__main__":
    main()
