"""Native task orchestration for Windows, macOS, and Linux (no shell syntax)."""

import argparse
import filecmp
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from build_environment import native_build_environment
from dev_server import descriptor_path, restart_if_requested

ROOT = Path(__file__).resolve().parents[1]
SUFFIX = ".exe" if os.name == "nt" else ""


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, **kwargs)


def target_directory(manifest="Cargo.toml"):
    result = run(
        "cargo",
        "metadata",
        "--no-deps",
        "--format-version",
        "1",
        "--manifest-path",
        manifest,
        capture_output=True,
        text=True,
    )
    return Path(json.loads(result.stdout)["target_directory"])


def stage(source, destination):
    if destination.is_file() and filecmp.cmp(source, destination, shallow=False):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    os.close(fd)
    temporary = Path(name)
    try:
        shutil.copy2(source, temporary)
        temporary.chmod(0o755)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def stage_launcher(directory):
    """`gft-gui` is `gft` under another name, never a second copy of it."""
    if SUFFIX == ".exe":
        # A link needs privileges on Windows; `gft gui` is the same launcher.
        (directory / "gft-gui.cmd").write_bytes(b'@"%~dp0gft.exe" gui %*\r\n')
        return
    launcher = directory / "gft-gui"
    if not launcher.is_symlink() or os.readlink(launcher) != "gft":
        launcher.unlink(missing_ok=True)
        launcher.symlink_to("gft")


def build(kind):
    # These task names share one artifact: the CLI includes the server.
    if kind not in ("cli", "server", "core"):
        raise ValueError(f"Unknown build target: {kind}")
    args = ["cargo", "build", "--release", "--locked", "-p", "graffitty-cli"]
    # Freeze Git metadata once before Cargo. GDScript/docs edits must not make
    # every native build script watch and rebuild the entire repository.
    run("uv", "run", ROOT / "tools/build_info.py")
    # macOS and Linux link the pinned static FFmpeg; Windows prepares its own
    # through prepare-windows-video.ps1.
    if os.name != "nt":
        run(sys.executable, ROOT / "tools/build_chromium_video.py")
    run(*args, env=native_build_environment())
    release = target_directory() / "release"
    stage(release / ("gft" + SUFFIX), ROOT / "dist/bin" / ("gft" + SUFFIX))
    stage_launcher(ROOT / "dist/bin")
    # The server's bundled filetree runtime; unchanged runtimes stay in place.
    run(sys.executable, ROOT / "tools/build_filetree_runtime.py")


def git_files(*patterns):
    result = run(
        "git",
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "--deduplicate",
        "-z",
        "--",
        *patterns,
        capture_output=True,
    )
    return [
        os.fsdecode(name)
        for name in result.stdout.split(b"\0")
        if name and (ROOT / os.fsdecode(name)).is_file()
    ]


def format_sources():
    run("ruff", "check", ".", "--select", "I", "--fix")
    run("ruff", "format", ".")
    for manifest in git_files("Cargo.toml", "**/Cargo.toml"):
        run("cargo", "fmt", "--all", "--manifest-path", manifest)
    for source in git_files(
        *(
            f"*.{ext}"
            for ext in ("c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "m", "mm")
        )
    ):
        run("clang-format", "-i", "--style=file", "--fail-on-incomplete-format", source)
    for script in git_files("*.gd"):
        run("gdscript-formatter", script)
    run(
        "oxfmt",
        "--write",
        "--no-error-on-unmatched-pattern",
        "**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,css,html}",
        ".github/workflows/*.{yml,yaml}",
        "**/{pyproject,Cargo,rustfmt,.rustfmt,ruff,.ruff}.toml",
        "mise.toml",
        "zensical.toml",
    )


def xdg_path(name, fallback):
    value = Path(os.environ.get(name) or fallback)
    return value if value.is_absolute() else Path(fallback)


def godot():
    launch = os.environ.get("GRAFFITTY_GODOT")
    if not launch and sys.platform == "darwin":
        launch = "/Applications/Godot.app/Contents/MacOS/Godot"
    launch = launch or "godot"
    if not shutil.which(launch):
        raise RuntimeError(
            "Godot not found. Set GRAFFITTY_GODOT to the native Godot 4.7 executable or add it to PATH."
        )
    return launch


def prepare_godot_links(project):
    """Restore Git symlinks checked out as text files on Windows."""
    if os.name != "nt":
        return False
    entries = run(
        "git", "ls-files", "--stage", "-z", "--", project, capture_output=True
    ).stdout.split(b"\0")
    changed = False
    for entry in filter(None, entries):
        metadata, name = entry.split(b"\t", 1)
        mode, oid, stage_number = metadata.split()
        if mode != b"120000" or stage_number != b"0":
            continue
        link = ROOT / os.fsdecode(name)
        if link.is_symlink():
            continue
        contents = run(
            "git", "cat-file", "blob", oid.decode(), capture_output=True
        ).stdout
        if not link.is_file() or link.read_bytes() != contents:
            raise RuntimeError(f"Cannot restore modified Git link: {link}")
        target = os.fsdecode(contents)
        resolved = (link.parent / target).resolve()
        if not resolved.is_relative_to(ROOT.resolve()) or not resolved.exists():
            raise RuntimeError(
                f"Missing or external target for Git link {link}: {resolved}"
            )
        link.unlink()
        try:
            link.symlink_to(Path(target), target_is_directory=resolved.is_dir())
        except OSError:
            link.write_bytes(contents)
            raise RuntimeError(
                "Enable Windows Developer Mode or run with symlink privileges to restore Godot's shared resource links."
            )
        changed = True
    return changed


def dev(extra):
    reload_scripts = "--reload" in extra
    if not reload_scripts:
        run("mise", "run", "dev:build")
    launch = godot()
    env = os.environ.copy()
    env.setdefault("GRAFFITTY_INITIAL_PWD", env.get("MISE_ORIGINAL_CWD", str(ROOT)))
    env.setdefault(
        "GRAFFITTY_SERVER", str(ROOT / "dist/bin" / ("gft" + SUFFIX))
    )
    env["PATH"] = str(ROOT / "dist/bin") + os.pathsep + env.get("PATH", "")
    if not reload_scripts:
        restart_if_requested(env["GRAFFITTY_SERVER"], descriptor_path(env, extra), env)
    # Development uses dist/bin through PATH; it must not replace an installed
    # release launcher or register another Graffitty application.
    run("uv", "run", "tools/build_info.py")
    project = ROOT / "frontends/godot/project"
    links_changed = prepare_godot_links(project)
    # A fresh checkout has no extension registry. Import before running the
    # scene so Godot discovers the native classes and prepares its resources.
    if links_changed or not (project / ".godot/extension_list.cfg").is_file():
        run(launch, "--headless", "--editor", "--path", project, "--import", env=env)
    if os.name != "nt":
        config = xdg_path("XDG_CONFIG_HOME", Path.home() / ".config")
        override = project / "override.cfg"
        if not override.exists() or override.is_symlink():
            override.unlink(missing_ok=True)
            override.symlink_to(config / "graffitty/override.cfg")
    fallback = (
        Path(os.environ.get("LOCALAPPDATA", Path.home())) / "graffitty/state"
        if os.name == "nt"
        else Path.home() / ".local/state"
    )
    directory = xdg_path("XDG_STATE_HOME", fallback) / "graffitty"
    directory.mkdir(parents=True, exist_ok=True)
    command = [
        launch,
        "--log-file",
        str(directory / "graffitty.log"),
        "--path",
        str(project),
        "res://scenes/terminal.tscn",
        "--resolution",
        "1600x1000",
        "--",
        *extra,
    ]
    if os.name != "nt":
        command = [sys.executable, str(ROOT / "tools/dev_instance.py"), *command]
    run(*command, env=env)


def android_sdk():
    if os.name == "nt":
        fallback = (
            Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local"))
            / "Android/Sdk"
        )
    else:
        fallback = Path.home() / (
            "Library/Android/sdk" if sys.platform == "darwin" else "Android/Sdk"
        )
    return Path(
        os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or fallback
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "task",
        choices=(
            "cli:build",
            "core:build",
            "server:build",
            "dev",
            "format",
            "remote:server",
            "remote:share",
            "android:vm",
        ),
    )
    args, extra = parser.parse_known_args()
    try:
        if args.task.endswith(":build"):
            build(args.task.split(":")[0])
        elif args.task == "dev":
            dev(extra)
        elif args.task == "format":
            format_sources()
        elif args.task == "remote:server":
            run(ROOT / "dist/bin" / ("gft" + SUFFIX), "server", *extra)
        elif args.task == "remote:share":
            run(
                godot(),
                "--path",
                ROOT / "frontends/godot/project",
                "res://scenes/terminal.tscn",
                "--",
                "--remote-listen=127.0.0.1:7183",
                *extra,
            )
        elif args.task == "android:vm":
            run(
                android_sdk() / "emulator" / ("emulator" + SUFFIX),
                "-avd",
                "graffitty-e2e-api36",
                "-no-window",
                "-no-audio",
                "-no-snapshot",
                "-gpu",
                "host",
                "-port",
                "5580",
                *extra,
            )
    except subprocess.CalledProcessError as error:
        return error.returncode
    except (OSError, RuntimeError) as error:
        print(f"[{args.task}] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
