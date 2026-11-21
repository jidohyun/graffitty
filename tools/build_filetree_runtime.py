#!/usr/bin/env python3
"""Stage the read-only bundled filetree runtime: Neovim, pinned plugins and config.

Every input is pinned in packaging/filetree/lock.json. Release archives are
checked by SHA-256 and plugins by Git commit; nothing is downloaded at
runtime.

The result is a directory that packaging copies beside gft unchanged.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "packaging/filetree/lock.json"
CONFIG = ROOT / "apps/server/filetree/init.lua"
# Not needed by a filetree or a fallback editor: help pages, tutor, man pages,
# desktop entries and icons.
PRUNE = ["share/nvim/runtime/doc", "share/nvim/runtime/tutor", "share/man",
         "share/icons", "share/applications", "share/metainfo"]


def host_platform():
    system = {"darwin": "macos", "linux": "linux", "win32": "windows"}.get(sys.platform)
    machine = {"arm64": "aarch64", "aarch64": "aarch64", "ARM64": "aarch64",
               "x86_64": "x86_64", "AMD64": "x86_64", "amd64": "x86_64"}.get(platform.machine())
    if not system or not machine:
        raise SystemExit(f"Unsupported host: {sys.platform} {platform.machine()}")
    return f"{system}-{machine}"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, expected, cache):
    """Download once into the cache; reject anything that does not match the lock."""
    path = cache / url.rsplit("/", 1)[1]
    if path.is_file() and sha256(path.read_bytes()) == expected:
        return path.read_bytes()
    cache.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if sha256(data) != expected:
        raise SystemExit(f"Checksum mismatch for {url}")
    temporary = path.with_suffix(path.suffix + ".next")
    temporary.write_bytes(data)
    os.replace(temporary, path)
    return data


def extract(data, url, destination):
    if url.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.namelist():
                target = (destination / member).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise SystemExit(f"Unsafe archive member: {member}")
            archive.extractall(destination)
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            archive.extractall(destination, filter="data")


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE).stdout.strip()


def plugin(entry, cache, destination):
    """Export only the runtime paths of the exact commit. Tests, docs and extras
    (including Fyler's long test names that break Windows checkouts) never land."""
    repository = cache / "plugins" / entry["name"]
    if not (repository / ".git").is_dir():
        repository.mkdir(parents=True, exist_ok=True)
        git("init", "-q", cwd=repository)
        git("remote", "add", "origin", entry["repository"], cwd=repository)
    commit = entry["commit"]
    if subprocess.run(["git", "cat-file", "-e", commit + "^{commit}"], cwd=repository,
                      stderr=subprocess.DEVNULL).returncode:
        git("fetch", "-q", "--depth=1", "origin", commit, cwd=repository)
    if git("rev-parse", commit + "^{commit}", cwd=repository) != commit:
        raise SystemExit(f"{entry['name']} does not resolve to the locked commit")
    archive = subprocess.run(["git", "archive", "--format=tar", commit, "--", *entry["paths"]],
                             cwd=repository, check=True, stdout=subprocess.PIPE).stdout
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(destination, filter="data")


def expected_manifest(lock, target):
    executable = "nvim/bin/" + ("nvim.exe" if target.startswith("windows") else "nvim")
    return {
        "platform": target,
        "neovim": lock["neovim"]["version"],
        "nvim": executable,
        "vimruntime": "nvim/share/nvim/runtime",
        "plugins": {entry["name"]: entry["commit"] for entry in lock["plugins"]},
        "init_sha256": sha256(CONFIG.read_bytes()),
    }


def build(target, output, cache, force=False, neovim_prefix=None):
    lock = json.loads(LOCK.read_text())
    neovim = lock["neovim"]
    asset = neovim["platforms"].get(target)
    if not asset:
        raise SystemExit(f"No Neovim release is locked for {target}")
    pack_lock = {"plugins": {
        entry["name"]: {
            "src": entry["repository"],
            "rev": entry["commit"],
            "version": f"'{entry['commit']}'",
        }
        for entry in lock["plugins"]
    }}
    pack_lock_bytes = (json.dumps(pack_lock, indent=2) + "\n").encode()
    manifest = expected_manifest(lock, target)
    manifest["pack_lock_sha256"] = sha256(pack_lock_bytes)
    if neovim_prefix:
        version = subprocess.check_output([str(neovim_prefix / "bin/nvim"), "--version"], text=True)
        if version.splitlines()[0] != "NVIM v" + neovim["version"]:
            raise SystemExit("Native Neovim does not match packaging/filetree/lock.json")
        manifest["input_binary_sha256"] = sha256((neovim_prefix / "bin/nvim").read_bytes())
    # Keep an identical runtime in place: running trees may be using it.
    try:
        current = json.loads((output / "manifest.json").read_text())
    except (OSError, ValueError):
        current = None
    pack_config = Path("packages/nvim-pack-lock.json")
    if current == manifest and not force and (output / pack_config).is_file():
        return output
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=output.name + ".", dir=output.parent))
    try:
        unpacked = stage / "unpacked"
        if neovim_prefix:
            shutil.copytree(neovim_prefix, stage / "nvim", symlinks=True)
        else:
            extract(fetch(asset["url"], asset["sha256"], cache), asset["url"], unpacked)
            os.replace(unpacked / asset["root"], stage / "nvim")
            shutil.rmtree(unpacked)
        for relative in PRUNE:
            path = stage / "nvim" / relative
            if path.is_dir():
                shutil.rmtree(path)
        executable = stage / manifest["nvim"]
        if not executable.is_file() or not (stage / "nvim/share/nvim/runtime").is_dir():
            raise SystemExit(f"Unexpected Neovim archive layout for {target}")
        licenses = stage / "licenses"
        licenses.mkdir()
        (licenses / "neovim-LICENSE.txt").write_bytes(
            fetch(neovim["license"]["url"], neovim["license"]["sha256"], cache / "neovim-license"))
        # Neovim appends "-data" to stdpath("data") on Windows.
        pack_data = "packages-data" if target.startswith("windows") else "packages"
        for entry in lock["plugins"]:
            directory = stage / pack_data / "site/pack/core/opt" / entry["name"]
            plugin(entry, cache, directory)
            shutil.copy2(directory / "LICENSE", licenses / f"{entry['name']}-LICENSE.txt")
        (stage / pack_config).parent.mkdir(exist_ok=True)
        (stage / pack_config).write_bytes(pack_lock_bytes)
        shutil.copy2(CONFIG, stage / "init.lua")
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Replace the generated runtime as a whole; never merge with an old one.
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            shutil.rmtree(previous)
        if output.exists():
            os.replace(output, previous)
        os.replace(stage, output)
        shutil.rmtree(previous, ignore_errors=True)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", default=host_platform(),
                        help="Target such as macos-aarch64 or windows-x86_64 (default: this host)")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/filetree")
    parser.add_argument("--cache", type=Path, default=ROOT / ".cache/filetree")
    parser.add_argument("--force", action="store_true", help="Rebuild even if the runtime is current")
    parser.add_argument("--neovim-prefix", type=Path, help="Native install prefix of the locked Neovim version")
    args = parser.parse_args()
    print(build(args.platform, args.output.absolute(), args.cache.absolute(), args.force,
                args.neovim_prefix.resolve() if args.neovim_prefix else None))


if __name__ == "__main__":
    main()
