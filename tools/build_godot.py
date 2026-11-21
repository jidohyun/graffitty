"""Build and stage the Godot extension (libgraffitty) using the host's native build tools."""

import argparse
import filecmp
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from build_environment import native_build_environment

ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / "frontends/godot/extension"
STAGED = ROOT / "frontends/godot/project/addons/graffitty/bin"
ARCHITECTURES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "arm64",
    "arm64": "arm64",
}


def library_names():
    """Cargo's output and the staged name graffitty.gdextension loads on this host."""
    if sys.platform == "darwin":
        return "libgraffitty.dylib", "libgraffitty.macos.dylib"
    architecture = ARCHITECTURES.get(platform.machine().lower())
    if sys.platform.startswith("linux") and architecture:
        return "libgraffitty.so", f"libgraffitty.linux.{architecture}.so"
    raise SystemExit(
        f"Unsupported Godot extension host: {sys.platform} {platform.machine()}"
    )


def zig_directory(env):
    """ghostty's VT library is built by Zig at the exact version mise.toml pins."""
    try:
        where = subprocess.run(
            ["mise", "where", "zig"],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(
            "Cannot locate zig: ensure mise is available in this shell and run 'mise install'."
        )
    directory = Path(where) / "bin"
    if not (directory / "zig").is_file():
        raise SystemExit(
            "Zig missing: run 'mise install' (version pinned in mise.toml)."
        )
    return directory


def target_directory(env):
    result = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=EXTENSION,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(json.loads(result.stdout)["target_directory"])


def stage(library, destination):
    """Replace destination atomically; an identical build leaves it untouched."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    # One staging file per build: concurrent builds (agents, a second mise dev)
    # otherwise share it, and one build's rename leaves the other signing nothing.
    descriptor, name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    os.close(descriptor)
    temporary = Path(name)
    try:
        shutil.copy2(library, temporary)
        if sys.platform == "darwin":
            # Copying invalidates the signature the linker left, and Godot's dlopen
            # refuses the library outright ("code signature does not cover entire
            # file"). Ad-hoc sign the copy so a fresh build is loadable.
            subprocess.run(
                ["codesign", "--force", "--sign", "-", str(temporary)], check=True
            )
        if not (
            destination.is_file() and filecmp.cmp(temporary, destination, shallow=False)
        ):
            temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def build(profile):
    built, staged = library_names()
    env = native_build_environment()
    env["PATH"] = str(zig_directory(env)) + os.pathsep + env.get("PATH", "")
    subprocess.run(
        ["uv", "run", str(ROOT / "tools/build_info.py")], cwd=ROOT, env=env, check=True
    )
    # The pinned static FFmpeg for browser video; no distro codec libraries.
    subprocess.run(
        [sys.executable, str(ROOT / "tools/build_chromium_video.py")],
        cwd=ROOT,
        env=env,
        check=True,
    )
    env["GRAFFITTY_VIDEO_REQUIRED"] = "1"
    subprocess.run(
        ["cargo", "build", "--profile", profile, "--locked"],
        cwd=EXTENSION,
        env=env,
        check=True,
    )
    library = (
        target_directory(env) / ("debug" if profile == "dev" else "release") / built
    )
    stage(library, STAGED / staged)
    print(f"installed -> {STAGED / staged}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("dev", "release"), default="release")
    args = parser.parse_args(argv)
    if os.name == "nt":
        command = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "tools/build-windows.ps1"),
            "-BuildProfile",
            args.profile,
        ]
        try:
            return subprocess.run(
                command, cwd=ROOT, env=native_build_environment(), check=False
            ).returncode
        except OSError as error:
            print(f"Godot extension build failed: {error}", file=sys.stderr)
            return 1
    try:
        build(args.profile)
    except subprocess.CalledProcessError as error:
        return error.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
