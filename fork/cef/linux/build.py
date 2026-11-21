#!/usr/bin/env python3
"""Apply/build/package the pinned Linux x64/ARM64 Chrome-style DMA-BUF capture fork."""

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE.parent / "pins.json").read_text())


def defines(arch):
    return (
        "is_official_build=false is_component_build=false dcheck_always_on=false symbol_level=0 "
        f'blink_symbol_level=0 target_cpu="{arch}" use_remoteexec=false '
        "use_sysroot=true cef_use_gtk=false"
    )


def run(*args, **kwargs):
    print("+", *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def inputs():
    return {
        str(p.relative_to(HERE.parent)): sha(p)
        for p in [
            HERE.parent / "pins.json",
            HERE.parent / "native_tabs.patch",
            HERE.parent / "native_tabs.cc",
            HERE.parent / "native_tabs.h",
            HERE.parent / "graffitty_history.cc",
            HERE.parent / "graffitty_history.h",
            HERE.parent / "session_lifetime.h",
            HERE.parent / "session_lifetime.patch",
            *sorted(HERE.glob("*.py")),
            HERE / "cef.patch",
            HERE / "chromium.patch",
            HERE / "vulkan_dmabuf_import.patch",
            HERE / "offscreen_window.patch",
            HERE / "wayland_cursor.patch",
            HERE / "native_window.patch",
            HERE / "native_tabs.patch",
            HERE / "linux_native_window.cc",
            HERE / "linux_native_window.h",
            HERE / "chrome_gpu_capture.cc",
            HERE / "chrome_gpu_capture.h",
        ]
    }


def verify_args(out, arch):
    actual = {}
    for line in (out / "args.gn").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            actual[key.strip()] = value.strip()
    required = {
        "target_cpu": f'"{arch}"',
        "is_debug": "false",
        "is_official_build": "false",
        # Non-official builds default to fatal DCHECKs; shipped Chrome has none.
        "dcheck_always_on": "false",
        "is_component_build": "false",
        "symbol_level": "0",
        "blink_symbol_level": "0",
        "use_remoteexec": "false",
        "use_sysroot": "true",
        "cef_use_gtk": "false",
    }
    for key, value in required.items():
        if actual.get(key) != value:
            raise SystemExit(f"Unrecorded Linux configuration: expected {key}={value}")


def apply_patch(tree, patch):
    base = ["git", "-C", str(tree), "apply", "--check"]
    if (
        subprocess.run(base + ["--reverse", str(patch)], capture_output=True).returncode
        == 0
    ):
        return
    if subprocess.run(base + [str(patch)], capture_output=True).returncode:
        raise SystemExit(f"Linux patch conflicts with checkout: {patch}")
    run("git", "-C", tree, "apply", patch)


def linux_native_tabs():
    # Keep Linux window operations out of shared source hashes so an unrelated
    # Linux feature does not invalidate the Windows/macOS runtime provenance.
    with tempfile.TemporaryDirectory(prefix="cef-linux-tabs-") as directory:
        tree = Path(directory)
        target = tree / "libcef/browser/native_tabs.cc"
        target.parent.mkdir(parents=True)
        target.write_bytes((HERE.parent / "native_tabs.cc").read_bytes())
        run("git", "init", "-q", tree)
        run("git", "-C", tree, "apply", HERE / "native_tabs.patch")
        return target.read_bytes()


def apply(src):
    cef = src / "cef"
    for path, key in ((src, "chromium"), (cef, "cef")):
        rev = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
        ).strip()
        if rev != PINS[key]:
            raise SystemExit(
                f"{path}: wrong revision {rev}; existing trees are never reset"
            )
    patch = HERE / "cef.patch"
    base = ["git", "-C", str(cef), "apply", "--check"]
    applied = (
        subprocess.run(base + ["--reverse", str(patch)], capture_output=True).returncode
        == 0
    )
    if (
        not applied
        and subprocess.run(base + [str(patch)], capture_output=True).returncode
    ):
        raise SystemExit("Linux CEF patch conflicts with checkout")
    copies = [
        (HERE / name, cef / "libcef/browser" / name)
        for name in ("chrome_gpu_capture.cc", "chrome_gpu_capture.h", "linux_native_window.cc", "linux_native_window.h")
    ] + [(HERE.parent / name, cef / "libcef/browser" / name)
         for name in ("graffitty_history.cc", "graffitty_history.h", "native_tabs.cc", "native_tabs.h", "session_lifetime.h")]
    prepared = [(linux_native_tabs() if source.name == "native_tabs.cc" else source.read_bytes(), target)
                for source, target in copies]
    for content, target in prepared:
        if target.exists() and target.read_bytes() != content:
            raise SystemExit(f"Refusing to overwrite divergent {target}")
    if not applied:
        run("git", "-C", cef, "apply", patch)
    for content, target in prepared:
        if not target.exists():
            target.write_bytes(content)
    apply_patch(cef, HERE / "native_window.patch")
    apply_patch(src, HERE / "offscreen_window.patch")
    apply_patch(src, HERE / "wayland_cursor.patch")
    apply_patch(src, HERE / "chromium.patch")
    apply_patch(src, HERE / "vulkan_dmabuf_import.patch")
    apply_patch(src, HERE.parent / "session_lifetime.patch")
    apply_patch(cef, HERE.parent / "native_tabs.patch")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=["apply", "configure", "build", "package"])
    p.add_argument("--source-root", required=True, type=Path)
    p.add_argument("--depot-tools", required=True, type=Path)
    p.add_argument("--arch", required=True, choices=["x64", "arm64"])
    p.add_argument("--jobs", type=int, default=16)
    p.add_argument("--output", type=Path)
    a = p.parse_args()
    if sys.platform != "linux" or platform.machine() != "x86_64" or a.jobs < 1:
        p.error("The pinned Chromium tools require an x64 Linux host and positive job count")
    src = a.source_root.resolve()
    depot = a.depot_tools.resolve()
    revision = subprocess.check_output(["git", "-C", str(depot), "rev-parse", "HEAD"], text=True).strip()
    if revision != PINS["depot_tools"]:
        raise SystemExit("depot_tools revision does not match the pinned build tools")
    env = dict(
        os.environ,
        DEPOT_TOOLS_UPDATE="0",
        GN_DEFINES=defines(a.arch),
        GN_OUT_CONFIGS=f"Release_GN_{a.arch}",
        CEF_INSTALL_SYSROOT="amd64" if a.arch == "x64" else "arm64",
        PATH=str(depot) + os.pathsep + os.environ["PATH"],
    )
    out = src / "out" / f"Release_GN_{a.arch}"
    if a.command == "configure":
        # gclient may run with the system Python without creating the Python
        # launcher used by gn. Bootstrap the pinned tools explicitly.
        run(depot / "ensure_bootstrap", cwd=depot, env=env)
        # Upstream's stock Chromium patches precede our CEF-only patch.
        run(sys.executable, src / "cef/tools/gclient_hook.py", cwd=src / "cef", env=env)
    apply(src)
    if a.command != "apply":
        verify_args(out, a.arch)
    if a.command == "build":
        before = inputs()
        run(
            depot / "autoninja",
            "-C",
            out,
            "-j",
            a.jobs,
            "cefsimple",
            "chrome_sandbox",
            cwd=src,
            env=env,
        )
        if inputs() != before:
            raise SystemExit("Build inputs changed; refusing to stamp")
        record = {
            "pins": {
                key: PINS[key]
                for key in ("cef", "chromium", "chromium_ref", "depot_tools", "branch")
            },
            "target": f"linux-{a.arch}",
            "host": platform.platform(),
            # Only the version line: the rest names the build machine's paths.
            "compiler": subprocess.check_output(
                [
                    str(src / "third_party/llvm-build/Release+Asserts/bin/clang"),
                    "--version",
                ],
                text=True,
            ).splitlines()[0],
            "inputs_sha256": before,
            "libcef_sha256": sha(out / "libcef.so"),
            "args_sha256": sha(out / "args.gn"),
        }
        (out / "graffitty-build.json").write_text(json.dumps(record, indent=2) + "\n")
    elif a.command == "package":
        stamp = json.loads((out / "graffitty-build.json").read_text())
        if (
            stamp["inputs_sha256"] != inputs()
            or stamp["libcef_sha256"] != sha(out / "libcef.so")
            or stamp["args_sha256"] != sha(out / "args.gn")
        ):
            raise SystemExit(
                "Build stamp no longer matches source/binary/configuration"
            )
        output = a.output.resolve() if a.output else None
        if (
            not output
            or output.exists()
            or Path(str(output) + ".provenance.json").exists()
        ):
            p.error("--output must name a new archive")
        if stamp.get("target") != f"linux-{a.arch}":
            raise SystemExit("Build stamp target does not match the requested architecture")
        destination = src / "cef/binary_distrib" / f"graffitty-linux-{a.arch}"
        # make_distrib appends the distribution mode to --distrib-subdir.
        produced = destination.with_name(destination.name + "_minimal")
        if destination.exists() or produced.exists():
            raise SystemExit(
                "Distribution directory already exists; inspect before packaging"
            )
        run(
            sys.executable,
            src / "cef/tools/make_distrib.py",
            "--output-dir=" + str(destination.parent),
            "--distrib-subdir=" + destination.name,
            "--ninja-build",
            f"--{a.arch}-build",
            "--minimal",
            "--no-symbols",
            "--no-docs",
            "--no-archive",
            cwd=src / "cef/tools",
            env=env,
        )
        produced.rename(destination)
        output.parent.mkdir(parents=True, exist_ok=True)
        run("tar", "--zstd", "--owner=0", "--group=0", "--numeric-owner",
            "-cf", output, "-C", destination.parent, destination.name)
        stamp["archive_sha256"] = sha(output)
        Path(str(output) + ".provenance.json").write_text(
            json.dumps(stamp, indent=2) + "\n"
        )


if __name__ == "__main__":
    main()
