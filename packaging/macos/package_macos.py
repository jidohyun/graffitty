#!/usr/bin/env python3
"""Assemble the app from built Graffitty artifacts and the prebuilt CEF host."""

import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

from bundle_dylibs import bundle as bundle_dylibs, macho

ROOT = pathlib.Path(__file__).resolve().parents[2]


def assemble(godot: pathlib.Path, output: pathlib.Path) -> None:
    dist = ROOT / "dist"
    host_relative = pathlib.Path((dist / "chromium-host-path.txt").read_text().strip())
    if host_relative.is_absolute() or ".." in host_relative.parts:
        raise SystemExit("Invalid chromium host path")
    host = dist / host_relative.parents[2]
    for path in [
        godot,
        dist / "terminal.pck",
        dist / "tools/gft-gui",
        dist / "tools/gft",
        dist / "addons/graffitty/bin/libgraffitty.macos.dylib",
        dist / "filetree/manifest.json",
        host / "Contents/MacOS/probe",
        host / "Contents/Resources/custom-cef-source.txt",
        ROOT / "assets/branding/exports/graffitty.icns",
    ]:
        if not path.is_file():
            raise SystemExit(f"Missing built input: {path}")
    if output.exists():
        raise SystemExit(f"Refusing to overwrite {output}")
    if not json.loads((dist / "filetree/manifest.json").read_text())["platform"].startswith("macos-"):
        raise SystemExit("Build dist/filetree for macOS with tools/build_filetree_runtime.py")
    # A prebuilt host must include current CEF sources, even when packaging
    # without rebuilding the host. Check before creating the output bundle.
    subprocess.run([
        sys.executable, str(ROOT / "apps/server/chromium/install_framework.py"),
        "--check", str(host),
    ], check=True)
    macos = output / "Contents/MacOS"
    resources = output / "Contents/Resources"
    runtime = resources / "graffitty"
    macos.mkdir(parents=True)
    runtime.mkdir(parents=True)
    shutil.copy2(godot, macos / "GraffittyRuntime")
    # The bundle executable is gft under the name it launches the app by.
    shutil.copy2(dist / "tools/gft", macos / "Graffitty")
    shutil.copy2(ROOT / "assets/branding/exports/graffitty.icns", resources / "Graffitty.icns")
    shutil.copy2(dist / "terminal.pck", runtime / "terminal.pck")
    # Official release templates discover the pack by executable name and
    # reject --path/--main-pack overrides.
    (resources / "GraffittyRuntime.pck").symlink_to("graffitty/terminal.pck")
    tools = runtime / "tools"
    tools.mkdir()
    for name in ["gft", "install_shell_integration.py"]:
        shutil.copy2(dist / "tools" / name, tools / name)
    # gft-gui is gft under another name, never a second copy of it.
    (tools / "gft-gui").symlink_to("gft")
    shutil.copytree(dist / "tools/shell-integration", tools / "shell-integration", symlinks=True)
    shutil.copytree(dist / "skills", runtime / "skills", symlinks=True)
    # Read-only bundled filetree (tools/build_filetree_runtime.py), found beside tools/gft.
    shutil.copytree(dist / "filetree", runtime / "filetree", symlinks=True)
    addon = runtime / "addons/graffitty/bin"
    addon.mkdir(parents=True)
    shutil.copy2(dist / "addons/graffitty/bin/libgraffitty.macos.dylib", addon)
    frameworks = output / "Contents/Frameworks"
    frameworks.mkdir()
    (frameworks / "addons").symlink_to("../Resources/graffitty/addons", target_is_directory=True)
    shutil.copytree(host, runtime / "Chromium GPU Host.app", symlinks=True)
    (runtime / "chromium-host-path.txt").write_text(
        "Chromium GPU Host.app/Contents/MacOS/probe\n"
    )
    shutil.copy2(
        ROOT / "packaging/macos/check-package.py", runtime / "tools/check-package.py"
    )
    info = {
        "CFBundleExecutable": "Graffitty",
        "CFBundleIdentifier": "dev.graffitty.terminal",
        "CFBundleName": "Graffitty",
        "CFBundleDisplayName": "Graffitty",
        "CFBundleIconFile": "Graffitty.icns",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.0.1",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
        "NSServices": [{
            "NSMenuItem": {"default": "Open in Graffitty"},
            "NSMessage": "openFolders",
            "NSPortName": "Graffitty",
            "NSSendTypes": ["NSFilenamesPboardType"],
            "NSSendFileTypes": ["public.folder"],
            "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
        }],
        "NSMicrophoneUsageDescription": "Graffitty uses the microphone when you dictate text into a pane.",
    }
    (output / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    licenses = resources / "Licenses"
    licenses.mkdir()
    for path in [
        godot.parent.parent / "Resources/GodotLicense.txt",
        ROOT / "fork/cef/artifacts/macos-arm64/sdk/LICENSE.txt",
        ROOT / "licenses/godotty-MIT.txt",
        ROOT / "fork/portable-pty/LICENSE",
        ROOT / ".cache/chromium-video/aarch64-apple-darwin/COPYING.LGPLv2.1",
    ]:
        if path.is_file():
            shutil.copy2(path, licenses / (path.parent.name + "-" + path.name))
    for path in sorted((dist / "filetree/licenses").iterdir()):
        shutil.copy2(path, licenses / ("filetree-" + path.name))
    # Graffitty's own license and notice (godotty's MIT notice is copied above).
    for name in ("LICENSE", "NOTICE"):
        shutil.copy2(ROOT / name, licenses / f"Graffitty-{name}.txt")
    # Resolve developer-installed dylibs on staged copies before signing.
    bundle_dylibs(output)
    # Preserve the stock runtime's permissions; CEF helpers are already signed by build.sh.
    signed = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(godot)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    permissions = plistlib.loads(signed.stdout) if signed.stdout.strip() else {}
    permissions["com.apple.security.cs.allow-jit"] = True
    permissions["com.apple.security.cs.disable-library-validation"] = True
    permissions["com.apple.security.device.audio-input"] = True
    entitlements = plistlib.dumps(permissions)
    with tempfile.NamedTemporaryFile(suffix=".plist") as file:
        file.write(entitlements)
        file.flush()
        subprocess.run(
            [
                "codesign",
                "--force",
                "--deep",
                "--sign",
                "-",
                "--options",
                "runtime",
                "--entitlements",
                file.name,
                str(output),
            ],
            check=True,
        )
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(output)], check=True
    )
    # `--deep` verification skips code under Contents/Resources: check every
    # Mach-O file on its own, as macOS does when it maps one.
    broken = [path for path in output.rglob("*")
              if path.is_file() and not path.is_symlink() and macho(path)
              and subprocess.run(["codesign", "--verify", "--strict", str(path)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode]
    if broken:
        raise SystemExit("Invalid code signatures:\n" + "\n".join(str(path) for path in broken))
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    runtime = parser.add_mutually_exclusive_group(required=True)
    runtime.add_argument("--godot", type=pathlib.Path, help="Explicit runtime binary")
    runtime.add_argument("--template", type=pathlib.Path, help="Godot macos.zip export template; selects the release runtime")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.template:
        with tempfile.TemporaryDirectory(prefix="graffitty-release-template-") as directory:
            with zipfile.ZipFile(args.template) as archive:
                name = "macos_template.app/Contents/MacOS/godot_macos_release.universal"
                binary = pathlib.Path(directory) / "GodotRelease"
                binary.write_bytes(archive.read(name))
                binary.chmod(0o755)
            assemble(binary, args.output.resolve())
    else:
        assemble(args.godot.resolve(), args.output.resolve())
