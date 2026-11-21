#!/usr/bin/env python3
"""Build every Linux release component inside the baseline container."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
try:
    import tomllib
except ImportError:
    import tomli as tomllib

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=ROOT, **kwargs):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, check=True, **kwargs)


def clean_at(tag, destination):
    described = subprocess.run(["git", "describe", "--tags", "--exact-match"], cwd=destination, capture_output=True, text=True)
    status = subprocess.run(["git", "status", "--porcelain"], cwd=destination, capture_output=True, text=True)
    return described.returncode == 0 and described.stdout.strip() == tag and status.returncode == 0 and not status.stdout


def checkout(url, tag, destination):
    # A cached checkout keeps its build objects; one that is not clean at the
    # pinned tag (an interrupted clone, a stray edit) is cloned again.
    if destination.exists() and not clean_at(tag, destination):
        print(f"Replacing {destination}: not clean at {tag}", flush=True)
        shutil.rmtree(destination)
    if not destination.exists():
        run("git", "clone", "--depth=1", "--branch", tag, url, destination)
    if not clean_at(tag, destination):
        raise SystemExit(f"Source must be clean at {tag}: {destination}")


def sources_for(cache, build, name, version):
    """Where a pinned third-party source lives: the cache keeps one version of
    each, with its build objects, and drops the others."""
    if cache is None:
        return build / name
    for stale in cache.glob(f"{name}-*"):
        if stale.name != f"{name}-{version}":
            shutil.rmtree(stale)
    return cache / f"{name}-{version}"


def build_accesskit(godot, build, cache, cargo_target, target, arch):
    # Match the API pinned by this Godot release, but build the SDK's Rust code
    # against the container's glibc baseline instead of consuming vendor archives.
    installer = (godot / "misc/scripts/install_accesskit.py").read_text()
    match = re.search(r'^ac_version\s*=\s*"([0-9.]+)"', installer, re.M)
    if not match:
        raise SystemExit("Godot's AccessKit version declaration needs review")
    provider = sources_for(cache, build, "accesskit", match[1])
    checkout("https://github.com/godotengine/godot-accesskit-c-static.git", match[1], provider)
    run("git", "submodule", "update", "--init", "--recursive", "--depth=1", cwd=provider)
    source = provider / "accesskit-c"
    run("cargo", "build", "--release", "--locked", "--target", target,
        "--manifest-path", source / "Cargo.toml")
    sdk = godot / "bin/build_deps/accesskit"
    (sdk / "include").mkdir(parents=True, exist_ok=True)
    library = sdk / f"lib/linux/{arch}/static"
    library.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "include/accesskit.h", sdk / "include/accesskit.h")
    shutil.copy2(cargo_target / f"{target}/release/libaccesskit.a", library / "libaccesskit.a")
    (sdk / "licenses").mkdir(exist_ok=True)
    for path in [*source.glob("LICENSE*"), source / "COPYING.LIB"]:
        shutil.copy2(path, sdk / "licenses" / path.name)
    return sdk


def build_chromium_host(arch, build, cache, jobs):
    """The Chromium runtime: the pinned CEF SDK and the Graffitty host built
    against it (apps/server/chromium/build-linux.sh). Returns its folder."""
    artifacts = ROOT / f"fork/cef/artifacts/linux-{'x64' if arch == 'x86_64' else 'arm64'}"
    archive = artifacts / f"cef-linux-{'x64' if arch == 'x86_64' else 'arm64'}-sdk.tar.zst"
    if not archive.is_file():
        raise SystemExit(f"Fetch the CEF SDK first: {artifacts}.dvc")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    extracted = sources_for(cache, build, "cef", digest[:16])
    sdk = extracted / f"graffitty-linux-{'x64' if arch == 'x86_64' else 'arm64'}"
    verify = ["sha256sum", "--quiet", "--check", artifacts / "SHA256SUMS-sdk-files"]
    if not sdk.is_dir() or subprocess.run(list(map(str, verify)), cwd=sdk).returncode:
        if extracted.exists():
            shutil.rmtree(extracted)
        extracted.mkdir(parents=True)
        run("tar", "--zstd", "-xf", archive, "-C", extracted)
        run(*verify, cwd=sdk)
    run("bash", "apps/server/chromium/build-linux.sh", env=dict(os.environ, CEF_ROOT=str(sdk), BUILD_JOBS=str(jobs)))
    host = ROOT / "dist" / (ROOT / "dist/chromium-host-path.txt").read_text().strip()
    return host.parent


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--check", action="store_true", help="Run native packaging tests without a full build")
    p.add_argument("--cache", type=Path, help="Persistent cache: toolchains, downloads, Cargo output, Godot and Neovim builds")
    args = p.parse_args()
    os.environ["LC_ALL"] = "C"
    if platform.libc_ver() != ("glibc", "2.35"):
        raise SystemExit("Use the Ubuntu 22.04 build container (glibc 2.35)")
    if args.check:
        run("python3", "-m", "unittest", "discover", "-s", "packaging/linux", "-p", "test_*.py")
        run("python3", "packaging/linux/test_relocation.py")
        return
    if args.jobs < 1:
        p.error("--jobs must be positive")
    machine = platform.machine()
    arch = {"aarch64": "arm64", "x86_64": "x86_64"}[machine]
    target = f"{machine}-unknown-linux-gnu"
    config = tomllib.loads((ROOT / "mise.toml").read_text())["tools"]
    build = ROOT / "build/native"
    build.mkdir(parents=True, exist_ok=True)
    cache = args.cache.resolve() if args.cache else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
        os.environ["RUSTUP_HOME"] = str(cache / "rustup")
        os.environ["CARGO_HOME"] = str(cache / "cargo")
        os.environ["PATH"] = f"{cache / 'cargo/bin'}:{os.environ['PATH']}"
        os.environ["UV_CACHE_DIR"] = str(cache / "uv")
    cargo_target = cache / "target" if cache else ROOT / "target"
    os.environ["CARGO_BUILD_TARGET"] = target
    os.environ["CARGO_TARGET_DIR"] = str(cargo_target)
    os.environ["CARGO_BUILD_JOBS"] = str(args.jobs)
    if not shutil.which("cargo"):
        with urllib.request.urlopen("https://sh.rustup.rs", timeout=120) as response:
            installer = build / "rustup.sh"
            installer.write_bytes(response.read())
        run("sh", installer, "-y", "--profile", "minimal", "--default-host", target)
    elif cache:
        # A cached toolchain follows stable like a fresh install would.
        run("rustup", "update", "--no-self-update", "stable")
    zig_version = config["zig"]
    if not Path("/opt/zig/zig").exists():
        with urllib.request.urlopen("https://ziglang.org/download/index.json", timeout=120) as response:
            release = json.load(response)[zig_version][f"{machine}-linux"]
        archive = (cache or build) / f"zig-{zig_version}-{machine}.tar.xz"
        data = archive.read_bytes() if archive.exists() else b""
        if hashlib.sha256(data).hexdigest() != release["shasum"]:
            with urllib.request.urlopen(release["tarball"], timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != release["shasum"]:
                raise SystemExit("Zig checksum mismatch")
            archive.write_bytes(data)
        # Extract on the container filesystem; Zig has many small files and
        # does not belong in the source bind mount.
        with tempfile.TemporaryDirectory(prefix="graffitty-zig-", dir="/opt") as temporary:
            with tarfile.open(archive) as tar:
                directory = tar.getmembers()[0].name.split("/")[0]
                tar.extractall(temporary, filter="data")
            shutil.move(Path(temporary) / directory, "/opt/zig")
    if subprocess.check_output(["zig", "version"], text=True).strip() != zig_version:
        raise SystemExit("Installed Zig does not match mise.toml")
    run("python3", "tools/build_info.py")
    run("python3", "tools/build_chromium_video.py", "--target", target)
    run("cargo", "build", "--release", "--locked", "-p", "graffitty-cli")
    run("uv", "run", "--no-project", "--with", "websocket-client>=1.8,<2", "python",
        "-m", "unittest", "discover", "-s", "tests/server", "-p", "test_terminal_scene.py",
        env=dict(os.environ, GRAFFITTY_TEST_SERVER=str(cargo_target / f"{target}/release/gft")))
    run("cargo", "build", "--release", "--locked", "--manifest-path", "frontends/godot/extension/Cargo.toml")
    extension = ROOT / f"frontends/godot/project/addons/graffitty/bin/libgraffitty.linux.{arch}.so"
    extension.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(cargo_target / f"{target}/release/libgraffitty.so", extension)
    godot = sources_for(cache, build, "godot", config["godot"])
    checkout("https://github.com/godotengine/godot.git", config["godot"], godot)
    sdk = build_accesskit(godot, build, cache, cargo_target, target, arch)
    frame_patch = ROOT / "frontends/godot/modules/graffitty_wayland_frame/wayland-decorations.patch"
    run("git", "apply", frame_patch, cwd=godot)
    try:
        for kind in ("editor", "template_release"):
            run("scons", f"-j{args.jobs}", "platform=linuxbsd", f"arch={arch}", f"target={kind}",
                f"custom_modules={ROOT / 'frontends/godot/modules'}",
                "production=yes", "lto=none", "accesskit=yes", f"accesskit_sdk_path={sdk}", cwd=godot)
    finally:
        run("git", "apply", "--reverse", frame_patch, cwd=godot)
    # Pages render in the session server's Chromium.
    chromium = build_chromium_host(arch, build, cache, args.jobs)
    lock = json.loads((ROOT / "packaging/filetree/lock.json").read_text())
    nvim = sources_for(cache, build, "neovim", "v" + lock["neovim"]["version"])
    checkout("https://github.com/neovim/neovim.git", "v" + lock["neovim"]["version"], nvim)
    prefix = build / "neovim-install"
    run("make", f"-j{args.jobs}", "CMAKE_BUILD_TYPE=Release", f"CMAKE_INSTALL_PREFIX={prefix}", cwd=nvim)
    run("make", "install", cwd=nvim)
    run("python3", "tools/build_filetree_runtime.py", "--neovim-prefix", prefix)
    run("python3", "packaging/linux/prepare_bundle.py",
        "--godot", godot / f"bin/godot.linuxbsd.editor.{arch}",
        "--template", godot / f"bin/godot.linuxbsd.template_release.{arch}",
        # Its licences; with a build cache the checkout is outside build/native.
        "--godot-source", godot,
        "--server", cargo_target / f"{target}/release/gft",
        "--chromium-runtime", chromium)
    output = ROOT / f"dist/linux-{arch}"
    for binary in (output / "tools/gft", output / "gft-gui", output / "filetree/nvim/bin/nvim"):
        run(binary, "--version")


if __name__ == "__main__":
    main()
