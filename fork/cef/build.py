#!/usr/bin/env python3
"""Thin orchestration of pinned upstream CEF tools; never reset a source tree."""

import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / "pins.json").read_text())
SOURCES = ("chrome_gpu_capture.cc", "chrome_gpu_capture.h", "chrome_gpu_capture_mac.mm",
           "graffitty_history.cc", "graffitty_history.h",
           "native_tabs.cc", "native_tabs.h", "session_lifetime.h")
INPUTS = SOURCES + ("cef.patch", "chromium.patch", "native_tabs.patch", "session_lifetime.patch", "pins.json", "args.gn", "build.py")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def input_hashes():
    return {name: digest(HERE / name) for name in INPUTS}


def build_stamp(work):
    return work / "chromium/src/out" / PINS["output"] / "godot-cef-build.json"


def framework_binary(work):
    return (
        work
        / "chromium/src/out"
        / PINS["output"]
        / "Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
    )


def run(argv, cwd=None, env=None):
    print("+", shlex.join(map(str, argv)), flush=True)
    subprocess.run(list(map(str, argv)), cwd=cwd, env=env, check=True)


def revision(path):
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def environment(work):
    return dict(
        os.environ,
        DEPOT_TOOLS_UPDATE="0",
        GN_DEFINES=PINS["gn_defines"],
        GN_OUT_CONFIGS=PINS["output"],
        PATH=str(work / "depot_tools") + os.pathsep + os.environ["PATH"],
    )


def trees(work):
    src = work / "chromium/src"
    return src, src / "cef"


def check_revisions(work):
    src, cef = trees(work)
    for path, key in (
        (src, "chromium"),
        (cef, "cef"),
        (work / "depot_tools", "depot_tools"),
    ):
        if revision(path) != PINS[key]:
            raise SystemExit(
                f"{path}: expected {key} {PINS[key]}; refusing to update/reset it"
            )


def patch_check(tree, patch, reverse=False):
    argv = ["git", "-C", str(tree), "apply", "--check"]
    if reverse:
        argv.append("--reverse")
    return subprocess.run(argv + [str(patch)], capture_output=True).returncode == 0


def apply(work, verify_only=False):
    check_revisions(work)
    src, cef = trees(work)
    pending = []
    # Preflight everything before changing either checkout.
    for tree, name in ((src, "chromium.patch"), (src, "session_lifetime.patch"),
                       (cef, "cef.patch"), (cef, "native_tabs.patch")):
        patch = HERE / name
        if patch_check(tree, patch, reverse=True):
            continue
        if verify_only or not patch_check(tree, patch):
            raise SystemExit(
                f"{name} is missing or conflicts with local edits; reconcile it manually"
            )
        pending.append((tree, patch))
    for name in SOURCES:
        destination = cef / "libcef/browser" / name
        if (
            destination.exists()
            and destination.read_bytes() != (HERE / name).read_bytes()
        ):
            raise SystemExit(
                f"{destination} differs from the canonical source; refusing to overwrite it"
            )
        if verify_only and not destination.is_file():
            raise SystemExit(f"Missing {destination}")
    if not verify_only:
        for tree, patch in pending:
            run(["git", "-C", tree, "apply", patch])
        for name in SOURCES:
            destination = cef / "libcef/browser" / name
            if not destination.exists():
                shutil.copy2(HERE / name, destination)


def gn_args(path):
    return dict(
        tuple(part.strip() for part in line.split("=", 1))
        for line in path.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


def verify(work):
    apply(work, verify_only=True)
    actual = work / "chromium/src/out" / PINS["output"] / "args.gn"
    if gn_args(actual) != gn_args(HERE / "args.gn"):
        raise SystemExit(
            f"{actual} differs from the recorded configuration; refusing an unrecorded build"
        )
    print(
        "Pinned revisions, complete patches, capture sources and GN arguments verified."
    )


def bootstrap(work):
    # Upstream checkout/update can revert files: only invoke it in a NEW tree.
    if work.exists():
        raise SystemExit(
            "Bootstrap requires a new, nonexistent work directory. Existing trees use apply/build."
        )
    if any(char.isspace() for char in str(work)):
        raise SystemExit("Upstream CEF requires a work directory without spaces.")
    work.mkdir(parents=True)
    url = f"https://raw.githubusercontent.com/chromiumembedded/cef/{PINS['cef']}/tools/automate/automate-git.py"
    script = work / "automate-git.py"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != PINS["automate_sha256"]:
        raise SystemExit("Upstream automate-git.py checksum mismatch")
    script.write_bytes(data)
    depot = work / "depot_tools"
    run(
        [
            "git",
            "clone",
            "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
            depot,
        ]
    )
    run(["git", "-C", depot, "checkout", "--detach", PINS["depot_tools"]])
    env = environment(work)
    # --no-depot-tools-update below also skips depot_tools' own bootstrap
    # (its Python and CIPD tools), which the gn and ninja wrappers need.
    run([depot / "ensure_bootstrap"], cwd=depot, env=env)
    run(
        [
            sys.executable,
            script,
            f"--download-dir={work}",
            "--url=https://github.com/chromiumembedded/cef.git",
            f"--checkout={PINS['cef']}",
            f"--chromium-checkout={PINS['chromium_ref']}",
            f"--branch={PINS['branch']}",
            "--arm64-build",
            "--no-chromium-history",
            "--no-depot-tools-update",
            "--no-build",
            "--no-distrib",
        ],
        env=env,
    )
    check_revisions(work)
    src, cef = trees(work)
    # Upstream applies its stock CEF Chromium patches and generates its projects.
    # Our patches come AFTER that step; subsequent builds never rerun checkout.
    run([sys.executable, cef / "tools/gclient_hook.py"], cwd=cef, env=env)
    apply(work)
    verify(work)


def package(work, output):
    verify(work)
    src, _ = trees(work)
    framework = src / "out" / PINS["output"] / "Chromium Embedded Framework.framework"
    binary = framework / "Versions/A/Chromium Embedded Framework"
    if not binary.is_file():
        raise SystemExit("Build cef_framework before packaging")
    stamp = build_stamp(work)
    if not stamp.is_file():
        raise SystemExit(
            "Run this recipe's build command first to record a successful build"
        )
    built = json.loads(stamp.read_text())
    if built.get("inputs_sha256") != input_hashes() or built.get(
        "framework_binary_sha256"
    ) != digest(binary):
        raise SystemExit(
            "Sources or framework changed since the successful build; rebuild before packaging"
        )
    metadata = Path(str(output) + ".provenance.json")
    if output.exists() or metadata.exists():
        raise SystemExit(
            "Package output must be new; existing releases are never overwritten"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    # tar preserves framework symlinks. zstd drains the complete tar stream.
    tar = subprocess.Popen(
        ["tar", "-cf", "-", "-C", str(framework.parent), framework.name],
        stdout=subprocess.PIPE,
    )
    try:
        subprocess.run(
            ["zstd", "-9", "-T4", "--no-progress", "-o", str(output)],
            stdin=tar.stdout,
            check=True,
        )
    finally:
        tar.stdout.close()
        code = tar.wait()
    if code:
        raise SystemExit(f"tar failed: {code}")
    record = {
        "pins": PINS,
        "archive_sha256": digest(output),
        "framework_binary_sha256": digest(binary),
        "inputs_sha256": input_hashes(),
        "host": platform.platform(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "macos_sdk": subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True
        ).strip(),
    }
    metadata.write_text(json.dumps(record, indent=2) + "\n")
    print(
        f"Packaged {output}; provenance: {metadata}. No installed host or DVC release was changed."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("bootstrap", "apply", "verify", "build", "package")
    )
    parser.add_argument(
        "--work-root",
        required=True,
        type=Path,
        help="Explicit source/build directory; no external checkout path is assumed",
    )
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--output", type=Path, help="New .tar.zst output for package")
    args = parser.parse_args()
    work = args.work_root.resolve()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.command in ("bootstrap", "build", "package") and (
        sys.platform != "darwin" or platform.machine() != "arm64"
    ):
        parser.error("This recipe targets Apple Silicon macOS")
    if args.command == "bootstrap":
        bootstrap(work)
    elif args.command == "apply":
        apply(work)
    elif args.command == "verify":
        verify(work)
    elif args.command == "build":
        verify(work)
        inputs = input_hashes()
        src, _ = trees(work)
        run(
            [
                work / "depot_tools/autoninja",
                "-C",
                "out/" + PINS["output"],
                PINS["target"],
                "-j",
                args.jobs,
            ],
            cwd=src,
            env=environment(work),
        )
        verify(work)
        if inputs != input_hashes():
            raise SystemExit(
                "Canonical inputs changed during the build; refusing to stamp this result"
            )
        build_stamp(work).write_text(
            json.dumps(
                {
                    "inputs_sha256": inputs,
                    "framework_binary_sha256": digest(framework_binary(work)),
                },
                indent=2,
            )
            + "\n"
        )
    else:
        if not args.output or not str(args.output).endswith(".tar.zst"):
            parser.error("package requires --output <new-file.tar.zst>")
        package(work, args.output.resolve())


if __name__ == "__main__":
    main()
