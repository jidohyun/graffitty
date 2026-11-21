"""Private macOS GPU test launches with native window/activation evidence."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

_SOURCE = Path(__file__).resolve().parents[2] / "tests/native/e2e_background_guard.m"
_LIBRARY_NAME = "e2e_background_guard.dylib"
_CACHE_PREFIX = "graffitty-e2e-native-"
_cache_lock = threading.Lock()
_guard_cache = {}


def _guard_library() -> Path:
    """Compile once per source revision in a process-owned, mode-0700 directory."""
    fingerprint = hashlib.sha256(_SOURCE.read_bytes()).hexdigest()
    with _cache_lock:
        if fingerprint in _guard_cache:
            return _guard_cache[fingerprint][1]
        compiler = shutil.which("clang")
        if not compiler:
            raise RuntimeError(
                "Background E2E needs clang (Xcode Command Line Tools); use --headful to opt into visible tests"
            )
        directory = tempfile.TemporaryDirectory(prefix=_CACHE_PREFIX)
        library = Path(directory.name) / _LIBRARY_NAME
        compiler_env = os.environ.copy()
        # Nested replay runners inherit the Godot guard. Apple compiler helpers
        # can use a different architecture and must never load this test dylib.
        clear_background(compiler_env)
        try:
            result = subprocess.run(
                [
                    compiler,
                    "-dynamiclib",
                    "-fobjc-arc",
                    "-fblocks",
                    "-framework",
                    "AppKit",
                    "-framework",
                    "CoreGraphics",
                    str(_SOURCE),
                    "-o",
                    str(library),
                ],
                capture_output=True,
                text=True,
                timeout=60,
                env=compiler_env,
            )
            if result.returncode:
                raise RuntimeError(
                    f"Could not compile the background E2E guard: {result.stderr.strip()}; use --headful for visible tests"
                )
        except (OSError, subprocess.TimeoutExpired) as error:
            directory.cleanup()
            raise RuntimeError(
                f"Could not compile the background E2E guard: {error}; use --headful for visible tests"
            ) from error
        except BaseException:
            directory.cleanup()
            raise
        # Keep the TemporaryDirectory alive until all this runner's jobs finish.
        _guard_cache[fingerprint] = (directory, library)
        return library


def clear_background(env: dict[str, str]) -> None:
    """Remove only this guard's inherited injection and test launch markers."""
    recorded_library = env.get("GRAFFITTY_E2E_NATIVE_LIBRARY")
    libraries = []
    for library in env.get("DYLD_INSERT_LIBRARIES", "").split(os.pathsep):
        if not library:
            continue
        path = Path(library)
        ours = library == recorded_library or (
            path.name == _LIBRARY_NAME and path.parent.name.startswith(_CACHE_PREFIX)
        )
        if not ours:
            libraries.append(library)
    if libraries:
        env["DYLD_INSERT_LIBRARIES"] = os.pathsep.join(libraries)
    else:
        env.pop("DYLD_INSERT_LIBRARIES", None)
    for key in list(env):
        if key in (
            "GRAFFITTY_E2E_BACKGROUND",
            "GRAFFITTY_E2E_GUARD_ACTIVE",
        ) or key.startswith("GRAFFITTY_E2E_NATIVE_"):
            env.pop(key)


def prepare_background(env: dict[str, str], evidence: Path) -> list[str]:
    """Arm one Godot launch; its loaded guard removes itself from helper environments."""
    if sys.platform != "darwin":
        raise RuntimeError(
            "Background GPU E2E currently requires macOS; use --headful to opt into visible tests"
        )
    evidence = evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    if any(evidence.glob("native*.json")):
        raise RuntimeError(
            f"Background E2E requires a fresh evidence directory: {evidence}"
        )
    library = _guard_library()
    clear_background(env)
    previous = env.get("DYLD_INSERT_LIBRARIES")
    env.update(
        GRAFFITTY_E2E_BACKGROUND="1",
        GRAFFITTY_E2E_NATIVE_REPORT=str(evidence / "native.json"),
        GRAFFITTY_E2E_NATIVE_LIBRARY=str(library),
        DYLD_INSERT_LIBRARIES=os.pathsep.join(filter(None, [str(library), previous])),
    )
    return [
        "--rendering-driver",
        "metal",
        "--rendering-method",
        "forward_plus",
        "--disable-render-loop",
        "--max-fps",
        "60",
        "--audio-driver",
        "Dummy",
    ]


def background_failures(evidence: Path, pid: int | None = None) -> list[str]:
    """Require primary evidence and inspect every guarded Godot child as well."""
    primary = evidence / "native.json"
    failures = []
    if not primary.is_file():
        failures.append(
            "Native background guard report is missing (DYLD injection may have been ignored)"
        )
    for path in sorted(evidence.glob("native*.json")):
        try:
            report = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            failures.append(
                f"{path.name}: unreadable native background report: {error}"
            )
            continue
        if not isinstance(report, dict):
            failures.append(f"{path.name}: native background report must be an object")
            continue
        values = [
            report.get(key)
            for key in ("pid", "samples", "visible_samples", "active_samples")
        ]
        if any(
            type(value) is not int or value < 0 for value in values
        ) or not report.get("pid"):
            failures.append(f"{path.name}: invalid native background counters or PID")
            continue
        if path == primary and pid is not None and report["pid"] != pid:
            failures.append(
                f"{path.name}: report PID {report['pid']} does not match primary PID {pid}"
            )
        if path != primary and path.name != f"native-{report['pid']}.json":
            failures.append(f"{path.name}: report PID does not match child filename")
        minimum = 10 if path == primary else 1
        if report["samples"] < minimum:
            failures.append(
                f"{path.name}: native guard observed {report['samples']} samples, expected at least {minimum}"
            )
        if report["visible_samples"]:
            failures.append(
                f"{path.name}: test window was visible in {report['visible_samples']} native samples"
            )
        if report["active_samples"]:
            failures.append(
                f"{path.name}: test app was active in {report['active_samples']} native samples"
            )
    return failures
