#!/usr/bin/env python3
"""Build an isolated snapshot of current source in a Linux baseline container."""
import argparse
import fcntl
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--arch", choices=("arm64", "x86_64"), default={
        "arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64"}.get(platform.machine()))
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--resume", type=Path, help="Resume a failed workspace printed by this command")
    p.add_argument("--check", action="store_true", help="Only native packaging tests")
    p.add_argument("--cache", type=Path, help="Build cache for this CPU (default: in the user cache folder)")
    p.add_argument("--fresh", action="store_true", help="Build everything from scratch, without the build cache")
    args = p.parse_args()
    if not args.arch or args.jobs < 1:
        p.error("Choose a supported architecture and positive job count")
    if args.fresh and args.cache:
        p.error("--fresh builds without a cache; drop --cache")
    name = f"linux-{args.arch}"
    archive = ROOT / f"dist/graffitty-{name}.tar.gz"
    output = ROOT / f"dist/{name}"
    if not args.check and (archive.exists() or output.exists()):
        p.error(f"Output already exists: {output} or {archive}")
    image = f"graffitty-build-{name}"
    docker_platform = "linux/" + ("amd64" if args.arch == "x86_64" else "arm64")
    run("docker", "build", "--platform", docker_platform, "-t", image,
        "-f", ROOT / "packaging/linux/containers/linux.Dockerfile",
        ROOT / "packaging/linux/containers")
    parent = ROOT / "build/linux-containers"
    parent.mkdir(parents=True, exist_ok=True)
    if args.resume:
        work = args.resume.resolve()
        source = work / "source"
        if not work.is_relative_to(parent.resolve()) or not work.name.startswith(name + "-") or not (source / ".git").is_dir():
            p.error("--resume must name a workspace from this CPU's build")
    else:
        work = Path(tempfile.mkdtemp(prefix=name + "-", dir=parent))
        source = work / "source"
        # A private Git clone preserves version provenance, while the overlay includes
        # current edits. Host build caches/binaries and credentials are never mounted.
        run("git", "clone", "--quiet", "--no-hardlinks", ROOT, source)
        paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
        for raw in set(paths.split(b"\0")) - {b""}:
            relative = Path(os.fsdecode(raw))
            original, destination = ROOT / relative, source / relative
            if not original.exists() and not original.is_symlink():
                if destination.is_file() or destination.is_symlink():
                    destination.unlink()
                continue
            if original.is_dir() and not original.is_symlink():  # A submodule needs an explicit source checkout.
                raise SystemExit(f"Submodule source must be staged explicitly: {relative}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink():
                destination.unlink()
            shutil.copy2(original, destination, follow_symlinks=False)
        if not args.check:
            # Explicit data-only DVC inputs; never copy cached native binaries.
            # The CEF SDK is pinned for the bundle's Chromium runtime.
            inputs = ["assets", "apps/cli/assets", "frontends/godot/extension/fonts",
                      f"fork/cef/artifacts/linux-{'x64' if args.arch == 'x86_64' else 'arm64'}"]
            for relative in inputs:
                original = ROOT / relative
                if not original.is_dir():
                    raise SystemExit(f"Fetch required DVC input first: {relative}.dvc")
                shutil.copytree(original, source / relative, dirs_exist_ok=True, symlinks=True)
    if args.resume and not args.check:
        # A failure during post-export smoke checks can leave generated outputs.
        # Re-export these inside the isolated snapshot; installed copies are never touched.
        previous = source / f"dist/{name}"
        if previous.exists():
            shutil.rmtree(previous)
        (source / f"dist/graffitty-{name}.tar.gz").unlink(missing_ok=True)
    print(f"Build workspace: {work}", flush=True)
    extra = ["--check"] if args.check else []
    # Toolchains, downloads and compiled objects persist between builds of this
    # CPU; the source is still a fresh snapshot every time.
    mounts = []
    if not args.check and not args.fresh:
        default = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ("Library/Caches" if sys.platform == "darwin" else ".cache"))
        cache = (args.cache or default / "graffitty/linux-build" / name).resolve()
        cache.mkdir(parents=True, exist_ok=True)
        lock = open(cache / ".lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(f"Another build is using the cache {cache}; wait, pass --cache, or use --fresh")
        print(f"Build cache: {cache}", flush=True)
        mounts = ["--mount", f"type=bind,source={cache},target=/cache"]
        extra += ["--cache", "/cache"]
    # An explicitly named release version reaches the build inside.
    named = ["--env", "GRAFFITTY_BUILD_VERSION"] if "GRAFFITTY_BUILD_VERSION" in os.environ else []
    run("docker", "run", "--rm", "--platform", docker_platform, *named,
        "--mount", f"type=bind,source={source},target=/work", *mounts, image,
        "--jobs", args.jobs, *extra)
    if not args.check:
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source / f"dist/{name}", output, symlinks=True)
        shutil.copy2(source / f"dist/graffitty-{name}.tar.gz", archive)
        print(archive)
    # Keep failed workspaces for diagnosis; delete successful build intermediates.
    if not (args.resume and args.check):
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
