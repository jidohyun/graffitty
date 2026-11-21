#!/usr/bin/env python3
# /// script
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Test replays, record them with Movie Maker, or rebuild the test dashboard.

    uv run tests/godot/test_dashboard.py test [case ...]
    uv run tests/godot/test_dashboard.py record [case ...]
    uv run tests/godot/test_dashboard.py build

- `test` runs logic replays headless and visual replays with background
  GPU rendering on macOS. Use `--headless` to run only logic replays.
  Use `--headful` to open windows. Native-focus tests require it.
- `record` runs replays with `--write-movie` at 30 fps in the background.
  Use `--headful` to open windows. FFmpeg needs libsvtav1 for the AV1 MP4
  clips. Clips and outcomes go in `docs/developers/internals/tests/media/`.
- `build` writes the dashboard's README table and HTML video wall. It also
  lists fast rules from `tests/unit/` with their current results.

Cases in `tests/llm-e2e/suites/` define the steps. A case with a
`suites/<suite>/replays/<case>.gd` replay runs those steps at a person's
pace and draws the pointer, clicks, and keys on screen.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import tomllib
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support", "tools")]
from report_privacy import public_text
from av1 import check_encoder, encoder_args, probe_av1
from e2e_background import background_failures, clear_background, prepare_background
from e2e_bistro import share_installed_bistro
from e2e_server import PrivateServer
from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[2]
GODOT_ROOT = ROOT / "frontends/godot/project"
SUITES = ROOT / "tests" / "llm-e2e" / "suites" / "godot"
SHARED_SUITES = SUITES.parent / "shared"
PAGES = ROOT / "docs" / "developers" / "internals" / "tests"
MEDIA = PAGES / "media"
RESULTS = MEDIA / "results.json"
GODOT = os.environ.get("GODOT") or shutil.which("godot") or ("/Applications/Godot.app/Contents/MacOS/Godot" if sys.platform == "darwin" else "godot")
SHELL = os.environ.get("GRAFFITTY_TEST_SHELL") or ((shutil.which("pwsh.exe") or shutil.which("powershell.exe") or "powershell.exe") if os.name == "nt" else "/bin/sh")
FPS = 30
MAX_FRAMES = FPS * 240  # Saved-view cases need more than two minutes at human pace.
TIMEOUT_S = 300
MARKER = re.compile(r"^([A-Z0-9_]+_(?:PASS|FAIL)\b.*)$", re.MULTILINE)
CHECK = re.compile(r"^\[replay\] (PASS|FAIL) (.+)$", re.MULTILINE)


def cases() -> list[dict]:
    found = []
    for toml in sorted([*SUITES.glob("*/*.toml"), *SHARED_SUITES.glob("*/*.toml")]):
        data = tomllib.loads(toml.read_text(encoding="utf-8"))
        adapter = data.get("adapters", {}).get("godot", {})
        replay = (toml.parent / adapter["replay"]).resolve() if "replay" in adapter else toml.parent / "replays" / f"{toml.stem}.gd"
        found.append(
            {
                "suite": toml.parent.name,
                "name": data.get("name", toml.stem),
                "goal": data.get("goal", ""),
                "steps": (toml.parent / data.get("instructions", toml.stem + ".md")).resolve(),
                "replay": replay if replay.exists() else None,
                "runtime": data.get("runtime", "godot"),
                "platforms": data.get("platforms", []),
                "automation": data.get("automation", ""),
                "physical_device": data.get("physical_device", False),
                "record_client": data.get("record_client", False),
                "server_config": adapter.get("server_config", ""),
                "timeout_seconds": adapter.get("timeout_seconds", TIMEOUT_S),
                "shell": adapter.get("shell", SHELL),
                "requires_headful": data.get("requires_headful", False),
            }
        )
    return found


def keep_mise_tools(env: dict) -> None:
    """Isolating XDG_DATA_HOME must not hide mise's installed tools from nested
    `mise exec` runners; an empty tool store makes mise download everything."""
    if os.name == "nt":
        default = Path(os.environ["LOCALAPPDATA"]) / "mise"
    else:
        default = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "mise"
    env.setdefault("MISE_DATA_DIR", os.environ.get("MISE_DATA_DIR") or str(default))


def configure_owner(case: dict, env: dict, directory: Path) -> None:
    """Server configuration is fixture input, never written by a client replay."""
    source = case.get("server_config", "")
    if not source:
        return
    if "{{port}}" in source:
        import socket
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            source = source.replace("{{port}}", str(listener.getsockname()[1]))
    path = Path(env["XDG_CONFIG_HOME"]) / "graffitty/server.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def frontmost_app() -> str:
    """The application the person is using, to hand the focus back to."""
    if sys.platform != "darwin":
        return ""
    try:
        front = subprocess.run(
            ["lsappinfo", "front"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            encoding="utf-8",
        ).stdout.strip()
        info = subprocess.run(
            ["lsappinfo", "info", "-only", "bundleid", front],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            encoding="utf-8",
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    match = re.search(r'"CFBundleIdentifier"="([^"]+)"', info)
    return match.group(1) if match and "godot" not in match.group(1).lower() else ""


def needs_window(replay: Path) -> bool:
    """Replays needing a real display backend (hidden by default on macOS)."""
    # Thin replays often inherit their pixel assertions. The common harness
    # only defines optional capture helpers, so stop before inspecting it.
    harness = (ROOT / "tests/llm-e2e/replay/replay.gd").resolve()
    visited = set()
    while replay.resolve() not in visited and replay.resolve() != harness:
        visited.add(replay.resolve())
        source = replay.read_text(encoding="utf-8")
        if (
            "res://tests/android_workspace_replay.gd" in source
            or ".get_image(" in source
            or "gui_embed_subwindows = false" in source
            or bool(re.search(r"func client_needs_window\(\).*:\s*\n\s*return true", source))
            or bool(re.search(r"\b(screen_image|frames_during)\(|DisplayServer\.FEATURE_CLIPBOARD", source))
        ):
            return True
        parent = re.search(r'^extends\s+["\']([^"\']+)["\']', source, re.MULTILINE)
        if not parent:
            break
        path = parent.group(1)
        replay = GODOT_ROOT / path[6:] if path.startswith("res://") else replay.parent / path
        if not replay.is_file():
            break
    return False


def timeout_output(expired: subprocess.TimeoutExpired) -> str:
    # Windows communicate() can leave decoded text on TimeoutExpired even
    # though other subprocess paths return bytes for captured output.
    return "".join(
        part.decode("utf-8", errors="replace") if isinstance(part, bytes) else part or ""
        for part in (expired.stdout, expired.stderr)
    )


def test_one(case: dict, person: str, android: bool = False, headful: bool = False) -> dict:
    platform = "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux"
    if case.get("platforms") and platform not in case["platforms"]:
        return {"status": "not_applicable", "failed": [], "log": "",
                "windowed": False, "mode": "not_applicable", "wall_s": 0}
    android = android or case["suite"] == "android-simulated"
    windowed = headful or needs_window(case["replay"]) or case.get("requires_headful", False)
    command = [
        GODOT,
        "--path",
        str(GODOT_ROOT),
        "--script",
        str(case["replay"].resolve()),
    ]
    if not windowed or case["record_client"]:
        command.insert(1, "--headless")
    shell = case.get("shell", SHELL)
    command += ["--", "--shell=" + shell]
    # Its own log and state, not the ones of the application you are using.
    stem = f"{case['suite']}--{case['name']}"
    scratch = Path(tempfile.mkdtemp(prefix=f"graffitty-{stem}-"))
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))
    }
    # Nested Android-simulated runners start their own private owners. Keep the
    # explicit test binary override so they use the same frozen build too.
    if os.environ.get("GRAFFITTY_TEST_SERVER"):
        env["GRAFFITTY_TEST_SERVER"] = os.environ["GRAFFITTY_TEST_SERVER"]
    clear_background(env)
    env.pop("REPLAY_RETURN_FOCUS", None)
    env["GRAFFITTY_E2E_HEADFUL"] = "1" if headful else "0"
    # Focus tests control their native windows; an asynchronous activation of
    # the person's app would race those focus assertions.
    if headful and not case.get("requires_headful", False):
        env["REPLAY_RETURN_FOCUS"] = person
    # Isolate application data and captures too, but keep mise's installed tools.
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(scratch / kind.lower())
    keep_mise_tools(env)
    share_installed_bistro(scratch / "data")
    if android:
        env["GRAFFITTY_TOUCH_CONTROLS"] = "1"
        command.append("--touch-controls")
    started = time.monotonic()
    background = windowed and not headful
    setup_errors = []
    try:
        if background:
            render_args = prepare_background(env, scratch)
            if not case["record_client"]:
                command[1:1] = render_args
        configure_owner(case, env, scratch)
        with PrivateServer(env, scratch, shell):
            run = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=case.get("timeout_seconds", TIMEOUT_S),
                errors="replace",
                check=False,
                encoding="utf-8",
            )
        log, code = run.stdout + run.stderr, run.returncode
    except subprocess.TimeoutExpired as expired:
        log = timeout_output(expired)
        code = None
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        log, code = str(error), 1
        setup_errors.append(str(error))
    markers = MARKER.findall(log)
    script_errors = [line for line in log.splitlines() if "SCRIPT ERROR" in line or "[diagnostic guard] FAIL" in line or line.lstrip().startswith(("ERROR:", "WARNING:"))]
    native_errors = background_failures(scratch) if background and not setup_errors else []
    errors = setup_errors + script_errors + native_errors
    if code not in (0, None):
        errors.append(f"Godot exited with code {code} (0x{code & 0xffffffff:08x})")
    if not markers:
        errors.append("Replay did not emit a completion marker")
    passed = code == 0 and not errors and bool(markers) and markers[-1].split(":")[0].endswith("_PASS")
    if native_errors:
        log += "\n" + "\n".join(native_errors) + "\n"
    log_path = scratch / "replay.log"
    log_path.write_text(public_text(log), encoding="utf-8")
    return {
        "status": "timeout" if code is None else ("pass" if passed else "fail"),
        "exit_code": code,
        "failed": [text for outcome, text in CHECK.findall(log) if outcome == "FAIL"]
        + errors[:3],
        "log": str(log_path),
        "windowed": windowed,
        "mode": "headful" if headful else ("background" if background else "headless"),
        "wall_s": round(time.monotonic() - started, 1),
    }


def test(names: list[str], jobs: int, windows: bool = False, android: bool = False,
         suite: str | None = None, headful: bool = False, headless_only: bool = False) -> None:
    available = cases()
    if suite:
        available = [c for c in available if c["suite"] == suite]
        if not available:
            sys.exit("Unknown or empty suite: " + suite)
    runtime = [c for c in available if c["runtime"] == "android"]
    if runtime and (suite or any(c["name"] in names for c in runtime)):
        sys.exit("Android-runtime cases require an Android emulator/device, not Mac Godot. "
                 "Use `list --suite android-runtime` for procedures and existing ADB automation; "
                 "see tests/llm-e2e/ANDROID.md.")
    if runtime and not names:
        print("Android-runtime cases excluded from host run: " + ", ".join(c["name"] for c in runtime), flush=True)
    available = [c for c in available if c["runtime"] != "android"]
    if names:
        missing = set(names) - {c["name"] for c in available if c["replay"]}
        if missing:
            sys.exit("No scripted replay for: " + ", ".join(sorted(missing)))
    else:
        manual = [c["name"] for c in available if not c["replay"]]
        if manual:
            print("Manual cases without scripted replays: " + ", ".join(manual), flush=True)
    todo = [c for c in available if c["replay"] and (not names or c["name"] in names)]
    person = frontmost_app() if headful else ""
    failed = 0
    native_focus = [c for c in todo if c.get("requires_headful", False)]
    if native_focus and not headful:
        if names:
            sys.exit("Native focus/idle rendering requires --headful: " + ", ".join(c["name"] for c in native_focus))
        todo = [c for c in todo if c not in native_focus]
        print(
            "Skipping native focus/idle rendering tests (add --headful): "
            + ", ".join(c["name"] for c in native_focus),
            flush=True,
        )
    if headless_only:
        rendered = [c for c in todo if needs_window(c["replay"])]
        if rendered and names:
            sys.exit("These replays require GPU rendering; omit --headless: " + ", ".join(c["name"] for c in rendered))
        todo = [c for c in todo if c not in rendered]
        print(f"Skipping {len(rendered)} rendered replays (--headless).", flush=True)

    def report(case: dict, result: dict) -> None:
        nonlocal failed
        where = result["mode"]
        print(
            f"{case['suite']}/{case['name']}: {result['status']} ({result['wall_s']} s, {where})",
            flush=True,
        )
        for line in result["failed"]:
            print(f"    {line}", flush=True)
        if result["status"] != "pass":
            print(f"    Full log: {result['log']}", flush=True)
        elif result["mode"] == "background":
            print(f"    Evidence: {Path(result['log']).parent}", flush=True)
        failed += result["status"] not in ("pass", "not_applicable")

    # Logic runs can share the CPU; keep GPU work sequential to avoid resource
    # contention and keep explicitly requested headful windows one at a time.
    headless = [c for c in todo if not headful and not needs_window(c["replay"])]
    with ThreadPoolExecutor(max_workers=max(jobs, 1)) as pool:
        for case, result in zip(
            headless, pool.map(lambda c: test_one(c, person, android, headful), headless)
        ):
            report(case, result)
    for case in [c for c in todo if c not in headless]:
        report(case, test_one(case, person, android, headful))
    print(f"{len(todo) - failed} of {len(todo)} replays pass")
    sys.exit(1 if failed else 0)


def load_results() -> dict:
    return json.loads(RESULTS.read_text(encoding="utf-8")) if RESULTS.exists() else {}


def record_one(case: dict, headful: bool = False) -> dict:
    encoder = check_encoder()
    key = f"{case['suite']}/{case['name']}"
    stem = key.replace("/", "--")
    mp4, poster = (
        MEDIA / f"{stem}.mp4",
        MEDIA / f"{stem}.jpg",
    )
    for stale in (mp4, poster):
        stale.unlink(missing_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=f"graffitty-{stem}-"))
    env = {
        **{key: value for key, value in os.environ.items()
           if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))},
        "XDG_CONFIG_HOME": str(scratch / "config"),
        "XDG_STATE_HOME": str(scratch / "state"),
        "XDG_CACHE_HOME": str(scratch / "cache"),
        "XDG_DATA_HOME": str(scratch / "data"),
        "GRAFFITTY_FFMPEG": encoder,
        "GRAFFITTY_MOVIE_PAUSED": "0",
        "GRAFFITTY_E2E_HEADFUL": "1" if headful else "0",
    }
    keep_mise_tools(env)
    share_installed_bistro(scratch / "data")
    clear_background(env)
    env.pop("REPLAY_RETURN_FOCUS", None)
    if headful and not case.get("requires_headful", False):
        env["REPLAY_RETURN_FOCUS"] = frontmost_app()
    command = [
        GODOT,
        "--path",
        str(GODOT_ROOT),
        "--write-movie",
        str(mp4),
        "--fixed-fps",
        str(FPS),
        "--quit-after",
        str(MAX_FRAMES),
        "--script",
        str(case["replay"].resolve()),
        "--",
        "--shell=" + case.get("shell", SHELL),
        "--record",
    ]
    if case["record_client"]:
        # The fixture server stays headless; the video must show the client UI.
        movie_index = command.index("--write-movie")
        del command[movie_index:movie_index + 2]
        for option in ("--fixed-fps", "--quit-after"):
            index = command.index(option)
            del command[index:index + 2]
        command.insert(1, "--headless")
        command.append("--remote-movie=" + str(mp4))
    started = time.monotonic()
    setup_errors = []
    try:
        if not headful:
            render_args = prepare_background(env, scratch)
            if not case["record_client"]:
                command[1:1] = render_args
        configure_owner(case, env, scratch)
        with PrivateServer(env, scratch, case.get("shell", SHELL)):
            run = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=case.get("timeout_seconds", TIMEOUT_S),
                errors="replace",
                check=False,
                encoding="utf-8",
            )
        log, code = run.stdout + run.stderr, run.returncode
    except subprocess.TimeoutExpired as expired:
        log = timeout_output(expired)
        code = None
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        log, code = str(error), 1
        setup_errors.append(str(error))
    native_errors = background_failures(scratch) if not headful and not setup_errors else []
    if native_errors:
        log += "\n" + "\n".join(native_errors) + "\n"
    (MEDIA / f"{stem}.log").write_text(public_text(log), encoding="utf-8")
    markers = [m for m in MARKER.findall(log) if not m.startswith("AV1_MOVIE_")]
    script_errors = [line for line in log.splitlines() if "SCRIPT ERROR" in line or "[diagnostic guard] FAIL" in line or line.lstrip().startswith(("ERROR:", "WARNING:"))]
    passed = code == 0 and not (setup_errors or native_errors or script_errors) and bool(markers) and markers[-1].split(":")[0].endswith("_PASS")
    status = (
        "timeout"
        if code is None
        else ("pass" if passed else ("error" if "SCRIPT ERROR" in log else "fail"))
    )
    seconds = 0.0
    if mp4.exists() and mp4.stat().st_size > 0:
        try:
            probe, _stream = probe_av1(mp4)
            seconds = float(probe["format"]["duration"])
            if "AV1_MOVIE_PASS" not in log:
                status = "error"
        except (
            RuntimeError,
            subprocess.CalledProcessError,
            KeyError,
            ValueError,
        ) as error:
            status = "error"
            log += f"\nAV1 validation failed: {error}\n"
            (MEDIA / f"{stem}.log").write_text(public_text(log), encoding="utf-8")
        if seconds > 0:
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-loglevel",
                    "error",
                    "-ss",
                    f"{seconds * 0.45:.2f}",
                    "-i",
                    str(mp4),
                    "-frames:v",
                    "1",
                    "-vf",
                    "scale=480:-2",
                    str(poster),
                ],
                check=False,
            )
    else:
        status = "error" if code is not None else "timeout"
    return {
        "status": status,
        "checks": CHECK.findall(log),
        "wall_s": round(time.monotonic() - started, 1),
        "video_s": round(seconds, 1),
        "codec": "av1" if seconds > 0 and status == "pass" else "unverified",
        "recorded_at": datetime.now().astimezone().isoformat(timespec="minutes"),
        "mode": "headful" if headful else "background",
        "evidence": str(scratch),
    }


def record(names: list[str], jobs: int, suite: str | None = None, headful: bool = False) -> None:
    available = [c for c in cases() if not suite or c["suite"] == suite]
    if not available:
        sys.exit("Unknown or empty suite: " + str(suite))
    selected = [c for c in available if not names or c["name"] in names]
    runtime = [c for c in selected if c["runtime"] == "android"]
    if runtime and (suite or names):
        sys.exit("Android-runtime recording requires the emulator/device procedures; use tests/android/test_android_runtime.py.")
    missing_names = set(names) - {c["name"] for c in available if c["replay"]}
    if missing_names:
        sys.exit("No scripted replay for: " + ", ".join(sorted(missing_names)))
    MEDIA.mkdir(parents=True, exist_ok=True)
    results = load_results()
    todo = [c for c in selected if c["replay"]]
    native_focus = [c for c in todo if c.get("requires_headful", False)]
    if native_focus and not headful:
        if names:
            sys.exit("Native focus/idle rendering requires --headful: " + ", ".join(c["name"] for c in native_focus))
        todo = [c for c in todo if c not in native_focus]
        print("Skipping native focus/idle rendering tests (add --headful): " + ", ".join(c["name"] for c in native_focus), flush=True)
    missing = [c for c in todo if not c["replay"].exists()]
    for case in missing:
        print(
            f"{case['suite']}/{case['name']}: replay {case['replay']} does not exist",
            file=sys.stderr,
        )
    todo = [c for c in todo if c not in missing]
    failed = False
    with ThreadPoolExecutor(max_workers=max(jobs, 1)) as pool:
        for case, result in zip(todo, pool.map(lambda c: record_one(c, headful), todo)):
            key = f"{case['suite']}/{case['name']}"
            failed |= result["status"] != "pass"
            results[key] = result
            RESULTS.write_text(public_text(json.dumps(results, indent=1, sort_keys=True)), encoding="utf-8")
            print(
                f"{key}: {result['status']} ({result['video_s']} s of video)",
                flush=True,
            )

    if failed:
        raise SystemExit(1)


def fast_rules() -> tuple[list[tuple[str, str]], str]:
    subprocess.run(["cargo", "build", "-p", "graffitty-workspace-core", "--example", "graph_fixture"], cwd=ROOT, check=True)
    run = subprocess.run(
        [GODOT, "--headless", "--path", str(GODOT_ROOT), "--script", "tests/run.gd"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=300,
        errors="replace",
        check=False,
        encoding="utf-8",
    )
    rules = re.findall(r"^(PASS|FAIL) (\S+?)\.test_(\S+) \(", run.stdout, re.MULTILINE)
    summary = (
        re.findall(r"^\d+ passed, \d+ failed in [\d.]+ s$", run.stdout, re.MULTILINE)
        or ["not run"]
    )[-1]
    return [
        (status, f"{group.removesuffix('_test')}: {name.replace('_', ' ')}")
        for status, group, name in rules
    ], summary


ICON = {
    "pass": "✅ pass",
    "fail": "❌ fail",
    "error": "💥 error",
    "timeout": "⏱ timeout",
}


def build() -> None:
    results = load_results()
    all_cases = sorted(cases(), key=lambda case: (case["suite"], case["name"]))
    rules, rules_summary = fast_rules()
    lines = [
        "# Test dashboard",
        "",
        "Open [the video wall](index.html) to inspect recorded replays.",
        "Specifications live in `tests/llm-e2e/suites/`. A recorded pass covers that case's assertions, not full product acceptance.",
        "",
        "## Find a suite",
        "",
        "| Suite | Cases | Recorded passes | Other recorded outcomes |",
        "| --- | ---: | ---: | ---: |",
    ]
    for suite in sorted({c["suite"] for c in all_cases}):
        members = [c for c in all_cases if c["suite"] == suite]
        outcomes = [results[f"{suite}/{c['name']}"]["status"]
                    for c in members if f"{suite}/{c['name']}" in results]
        lines.append(
            f"| [{suite}](index.html#{suite}) | {len(members)} | {outcomes.count('pass')} | "
            f"{sum(status != 'pass' for status in outcomes)} |"
        )
    lines += [
        "", "Unrecorded cases are not passes. See each suite for failures, blocked cases, and missing recordings.",
        "", "## Update recordings", "",
        "1. Record Mac replays: `uv run tests/godot/test_dashboard.py record`.",
        "2. Import APK evidence: `uv run tests/godot/test_dashboard.py import-android EVIDENCE_DIRECTORY`.",
        "3. Rebuild this index: `uv run tests/godot/test_dashboard.py build`.",
    ]
    lines += [
        "",
        f"## Fast rules ({rules_summary})",
        "",
        "Build the isolated Rust graph fixture with `cargo build -p graffitty-workspace-core --example graph_fixture`, then run `godot --headless --path frontends/godot/project --script tests/run.gd`. No application sessions or model calls are used.",
        "",
        "The video wall retains every case, assertion, replay, recording, and full fast-rule result. This page lists only fast-rule failures below.",
        "",
    ]
    lines += [f"- ❌ {rule}" for status, rule in rules if status != "PASS"]
    lines += ["", "The video wall contains the full fast-rule results."]
    (PAGES / "README.md").write_text(public_text("\n".join(lines) + "\n"), encoding="utf-8")

    markdown = MarkdownIt("commonmark", {"html": False})
    cards = []
    for suite in sorted({c["suite"] for c in all_cases}):
        cards.append(f'<h2 id="{html.escape(suite, quote=True)}">{html.escape(suite)}</h2><div class=grid>')
        for case in [c for c in all_cases if c["suite"] == suite]:
            key = f"{case['suite']}/{case['name']}"
            stem = key.replace("/", "--")
            result = results.get(key, {})
            media = (
                f"<video src='media/{stem}.mp4' poster='media/{stem}.jpg' muted playsinline controls preload=none></video>"
                if (MEDIA / f"{stem}.mp4").exists()
                else "<div class=novideo>"
                + ("no replay yet" if not case["replay"] else "not recorded")
                + "</div>"
            )
            checks = "".join(
                f"<li class={s.lower()}>{html.escape(m)}</li>"
                for s, m in result.get("checks", [])
            )
            spec = case["steps"].read_text(encoding="utf-8")
            specification = (
                "<details class=spec><summary>LLM suite specification</summary>"
                + "<article>"
                + markdown.render(spec)
                + "</article>"
                + "<details><summary>Markdown source</summary><pre>"
                + html.escape(spec)
                + "</pre></details></details>"
            )
            cards.append(
                f"<div class='card {result.get('status', 'none')}'>{media}"
                f"<h3>{html.escape(case['name'])}</h3>"
                f"<p>{html.escape(case['goal'])}</p>"
                f"<p class=meta>{ICON.get(result.get('status'), 'not recorded')} · {result.get('video_s', '—')} s · {html.escape(result.get('codec', 'unverified').upper())} · {result.get('recorded_at', '')}</p>"
                + specification
                + (
                    f"<details><summary>Replay checks</summary><ul>{checks}</ul></details>"
                    if checks
                    else ""
                )
                + "</div>"
            )
        cards.append("</div>")
    rule_items = "".join(
        f"<li class={s.lower()}>{html.escape(r)}</li>" for s, r in rules
    )
    (
        PAGES / "index.html"
    ).write_text(public_text(f"""<!doctype html><meta charset=utf-8><title>Graffitty tests</title>
<style>
body{{font:14px -apple-system,system-ui,sans-serif;background:#111418;color:#dde3ea;margin:24px}}
a{{color:#8fc1ff}} h2{{margin:32px 0 12px;border-bottom:1px solid #2a313a;padding-bottom:6px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(480px,1fr));gap:16px}}
.card{{background:#1a1f26;border:1px solid #2a313a;border-radius:8px;padding:12px;border-top:3px solid #555}}
.card.pass{{border-top-color:#3fb950}} .card.fail{{border-top-color:#f85149}} .card.error,.card.timeout{{border-top-color:#d29922}}
video,.novideo{{width:100%;aspect-ratio:16/10;background:#000;border-radius:4px}}
.novideo{{display:flex;align-items:center;justify-content:center;color:#666}}
h3{{margin:10px 0 4px}} p{{margin:4px 0}} .meta{{color:#8b949e;font-size:12px}}
ul{{margin:6px 0;padding-left:20px}} li.pass::marker{{content:'✓ ';color:#3fb950}} li.fail::marker{{content:'✗ ';color:#f85149}}
summary{{cursor:pointer;padding:8px 0;color:#8fc1ff}}
.spec{{margin-top:10px;border-top:1px solid #394350}}
.spec article{{max-height:65vh;overflow:auto;line-height:1.6;padding:4px 8px}}
.spec h1{{font-size:20px}} .spec h2{{font-size:17px;margin:16px 0 8px}}
.spec pre{{white-space:pre-wrap;overflow-wrap:anywhere;background:#111418;padding:10px;border-radius:4px}}
.spec p{{margin:8px 0}} .spec code{{color:#b9d6f7}}
@media(max-width:540px){{.grid{{grid-template-columns:1fr}} body{{margin:12px}}}}
</style>
<h1>Graffitty tests</h1>
<p>Each clip replays an e2e case at a person's pace. Fast rules: {html.escape(rules_summary)}.</p>
{"".join(cards)}
<h2>Fast rules</h2><ul>{rule_items}</ul>
"""), encoding="utf-8")
    print(f"Wrote {PAGES / 'README.md'} and {PAGES / 'index.html'}")


def import_android(directory: Path) -> None:
    """Publish real APK recordings and checks into the existing replay gallery."""
    directory = directory.resolve()
    evidence = json.loads((directory / "results.json").read_text())
    known = {c["name"] for c in cases() if c["runtime"] == "android"}
    if set(evidence) - known:
        sys.exit("Evidence contains unknown Android cases")
    results = load_results()
    MEDIA.mkdir(parents=True, exist_ok=True)
    for name, outcome in evidence.items():
        source = directory / name
        stem = "android-runtime--" + name
        movie, poster = MEDIA / (stem + ".mp4"), MEDIA / (stem + ".jpg")
        seconds = 0.0
        if (source / "replay.mp4").exists():
            subprocess.run([check_encoder(), "-y", "-v", "error", "-i", str(source / "replay.mp4"),
                            "-map", "0:v:0", "-an", *encoder_args(), str(movie)], check=True)
            probe, _ = probe_av1(movie)
            seconds = float(probe["format"]["duration"])
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-ss", str(seconds * .45), "-i", str(movie),
                            "-frames:v", "1", "-vf", "scale=480:-2", str(poster)], check=True)
        else:
            movie.unlink(missing_ok=True)
            poster.unlink(missing_ok=True)
        state = json.loads((source / "last-state.json").read_text()) if (source / "last-state.json").exists() else {}
        checks = [["FAIL" if message in state.get("failures", []) else "PASS", message] for message in state.get("checks", [])]
        if (source / "assertions.json").exists():
            checks.extend(["PASS", message] for message in json.loads((source / "assertions.json").read_text()))
        if outcome.get("reason"): checks.append(["FAIL" if outcome["status"] == "fail" else "BLOCKED", outcome["reason"]])
        result = {"status": outcome["status"], "checks": checks, "video_s": round(seconds, 1),
                  "codec": "av1" if seconds else "none", "evidence": str(directory.relative_to(ROOT)) if directory.is_relative_to(ROOT) else str(directory),
                  "recorded_at": datetime.fromtimestamp((directory / "results.json").stat().st_mtime).astimezone().isoformat(timespec="minutes")}
        (MEDIA / (stem + ".log")).write_text(public_text(json.dumps(result, indent=2) + "\n" +
            "\n".join(path.read_text(errors="replace") for path in [source / "logcat.txt", source / "keystore.log"] if path.exists())))
        results["android-runtime/" + name] = result
        RESULTS.write_text(public_text(json.dumps(results, indent=1, sort_keys=True)))
        print(f"{name}: {outcome['status']} ({seconds:.1f}s)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("test")
    run.add_argument("names", nargs="*")
    run.add_argument("--suite", help="run only cases in a suite, e.g. android-simulated")
    run.add_argument("--touch-controls", action="store_true", help="run the suites with the Android UI/input profile in desktop Godot")
    run.add_argument("--jobs", type=int, default=4, help="headless replays at once")
    mode = run.add_mutually_exclusive_group()
    mode.add_argument("--headful", action="store_true", help="opt in to visible windows, including native-focus tests")
    mode.add_argument("--headless", action="store_true", help="only run logic replays; skip GPU rendering")
    run.add_argument(
        "--windows",
        action="store_true",
        help="compatibility option: rendered replays are now included by default; use --headful for visible windows",
    )
    rec = sub.add_parser("record")
    rec.add_argument("names", nargs="*")
    rec.add_argument("--suite", help="record only cases in a suite")
    rec.add_argument("--headful", action="store_true", help="opt in to visible windows while recording")
    rec.add_argument(
        "--jobs",
        type=int,
        default=1,
        help="concurrent recordings (default: 1 to limit GPU load)",
    )
    sub.add_parser("build")
    android_import = sub.add_parser("import-android", help="add APK runner evidence to the replay gallery")
    android_import.add_argument("directory", type=Path)
    listing = sub.add_parser("list")
    listing.add_argument("--suite")
    args = parser.parse_args()
    if args.command == "test":
        test(args.names, args.jobs, args.windows, args.touch_controls, args.suite, args.headful, args.headless)
    elif args.command == "list":
        selected = [c for c in cases() if not args.suite or c["suite"] == args.suite]
        if not selected:
            sys.exit("Unknown or empty suite: " + str(args.suite))
        for case in selected:
            runner = case["automation"] or ("Godot replay" if case["replay"] else "LLM/manual procedure")
            runtime = "physical Android device" if case["physical_device"] else case["runtime"]
            print(f"{case['suite']}/{case['name']} [{runtime}; {runner}] {case['steps'].relative_to(ROOT)}")
    elif args.command == "import-android":
        import_android(args.directory)
    elif args.command == "record":
        record(args.names, args.jobs, args.suite, args.headful)
    else:
        build()


if __name__ == "__main__":
    main()
