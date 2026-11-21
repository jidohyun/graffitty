#!/usr/bin/env python3
"""Export a native Linux desktop bundle from current source and built dependencies."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from check_godot import failed as godot_failed
from shared_libraries import bundle, needed
from abi import audit


def copy_tree(source, destination):
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(
        ".godot", ".git", "__pycache__"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-source", type=Path, default=ROOT / "build/native/godot",
                        help="Matching Godot source tree for engine/third-party notices")
    parser.add_argument("--template", type=Path, help="Release template built in the same container")
    parser.add_argument("--godot", required=True, help="Native Godot with matching export templates")
    parser.add_argument("--server", type=Path, required=True, help="Freshly built gft executable")
    parser.add_argument("--chromium-runtime", type=Path, required=True, help="Matching complete Linux CEF host runtime")
    parser.add_argument("--filetree-runtime", type=Path, default=ROOT / "dist/filetree",
                        help="Bundled filetree from tools/build_filetree_runtime.py")
    args = parser.parse_args()
    machine = platform.machine()
    arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x86_64"}.get(machine)
    if sys.platform != "linux" or not arch:
        parser.error("Run on native ARM64 or x86_64 Linux")
    source = ROOT / "frontends/godot/project"
    extension = source / f"addons/graffitty/bin/libgraffitty.linux.{arch}.so"
    triple = f"{'aarch64' if arch == 'arm64' else arch}-unknown-linux-gnu"
    ffmpeg_license = ROOT / ".cache/chromium-video" / triple / "COPYING.LGPLv2.1"
    for path in (args.server, extension, args.filetree_runtime / "manifest.json",
                 args.godot_source / "LICENSE.txt", args.godot_source / "COPYRIGHT.txt", ffmpeg_license):
        if not path.is_file():
            parser.error(f"Build the native dependency first: {path}")
    if json.loads((args.filetree_runtime / "manifest.json").read_text())["platform"] != f"linux-{'aarch64' if arch == 'arm64' else arch}":
        parser.error("The filetree runtime was built for another platform")
    for name in ("graffitty_chromium", "libcef.so", "icudtl.dat", "LICENSE.txt", "CREDITS.html"):
        if not (args.chromium_runtime / name).is_file():
            parser.error(f"Missing Chromium runtime file: {name}")
    stage = ROOT / f"build/linux-{arch}/project"
    output = ROOT / f"dist/linux-{arch}"
    archive = ROOT / f"dist/graffitty-linux-{arch}.tar.gz"
    # Never replace an installed or running runtime.
    if output.exists() or archive.exists():
        parser.error(f"Move the previous generated bundle/archive first: {output}, {archive}")
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    output.mkdir(parents=True)
    for directory in ("scenes", "config", "presets", "mods", "graffitty", "assets/icons",
                      "assets/branding/exports", "addons/source_assets"):
        copy_tree(source / directory, stage / directory)
    native = stage / "addons/graffitty/bin"
    native.mkdir(parents=True)
    shutil.copy2(extension, native)
    shutil.copy2(source / "addons/graffitty/graffitty.gdextension", native.parent)
    project = (source / "project.godot").read_text()
    (stage / "project.godot").write_text(project)
    preset = (Path(__file__).with_name("export_presets.cfg")).read_text()
    if args.template:
        preset += "\ncustom_template/release=" + json.dumps(str(args.template.resolve())) + "\n"
    (stage / "export_presets.cfg").write_text(preset.replace('@ARCH@', arch))
    for flags in (("--editor", "--import"),
                  ("--export-release", "Linux", str(output / "gft-gui"))):
        result = subprocess.run([args.godot, "--headless", "--path", str(stage), *flags],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(result.stdout, end="")
        if godot_failed(result.returncode, result.stdout):
            raise RuntimeError("Godot import/export failed")
    shutil.copy2(Path(__file__).with_name("install.py"), output)
    # Keep the freedesktop layout for the per-user application menu.
    shutil.copytree(source / "assets/branding/exports/linux/hicolor", output / "icons/hicolor")
    tools = output / "tools"
    tools.mkdir()
    shutil.copy2(args.server, tools / "gft")
    # The CLI and server must start on a machine without GPU libraries: VA-API
    # loads the system's libva on demand instead (va_loader_linux.c).
    gpu = [name for name in needed(tools / "gft") if name.startswith(("libva", "libdrm"))]
    if gpu:
        raise SystemExit(f"gft must not link {', '.join(gpu)}; libva is loaded on demand")
    shutil.copy2(ROOT / "tools/install_shell_integration.py", tools)
    shutil.copy2(ROOT / "tools/install_context_menu.py", tools)
    copy_tree(ROOT / "apps/server/shell-integration", tools / "shell-integration")
    copy_tree(ROOT / "skills/terminal-chromium", output / "skills/terminal-chromium")
    copy_tree(ROOT / "skills/graffitty", output / "skills/graffitty")
    copy_tree(args.chromium_runtime, output / "chromium-linux")
    (output / "chromium-host-path.txt").write_text("chromium-linux/graffitty_chromium\n")
    shutil.copytree(args.filetree_runtime, output / "filetree", symlinks=True)
    bundle(output, runtimes=("chromium-linux",))
    abi = audit(output, arch)
    licenses = output / "licenses"
    licenses.mkdir()
    shutil.copy2(args.godot_source / "LICENSE.txt", licenses / "Godot-LICENSE.txt")
    shutil.copy2(args.godot_source / "COPYRIGHT.txt", licenses / "Godot-COPYRIGHT.txt")
    shutil.copy2(ffmpeg_license, licenses / "FFmpeg-LGPLv2.1.txt")
    accesskit_licenses = args.godot_source / "bin/build_deps/accesskit/licenses"
    if accesskit_licenses.is_dir():
        shutil.copytree(accesskit_licenses, licenses / "accesskit")
    shutil.copy2(output / "chromium-linux/LICENSE.txt", licenses / "CEF-LICENSE.txt")
    shutil.copy2(output / "chromium-linux/CREDITS.html", licenses / "Chromium-CREDITS.html")
    for path in sorted((output / "filetree/licenses").iterdir()):
        shutil.copy2(path, licenses / ("filetree-" + path.name))
    for path, name in (("LICENSE", "Graffitty-LICENSE.txt"), ("NOTICE", "Graffitty-NOTICE.txt"),
                       ("frontends/godot/extension/fonts/OFL.txt", "bundled-fonts-OFL.txt"),
                       ("licenses/godotty-MIT.txt", "godotty-LICENSE.txt"),
                       ("fork/portable-pty/LICENSE.md", "portable-pty-LICENSE.txt")):
        shutil.copy2(ROOT / path, licenses / name)
    (output / "build.json").write_text(json.dumps({
        "abi": abi,
        "architecture": arch, "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
    }, indent=2) + "\n")
    (output / "PLATFORM").write_text(f"linux-{arch}\n")
    checks = []
    for path in sorted(output.rglob("*")):
        if path.is_file():
            checks.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(output)}\n")
    (output / "SHA256SUMS").write_text("".join(checks))
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(output, arcname="graffitty")
    print(archive)


if __name__ == "__main__":
    main()
