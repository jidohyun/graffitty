#!/usr/bin/env python3
"""Production Godot startup, reattachment, camera effects and final-pane lifecycle."""
import argparse
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/platform/windows", "tests/support")]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--godot", default=shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot")
    parser.add_argument("--cwd-mode", choices=("launch", "configured"), default="launch")
    parser.add_argument("--gpu", action="store_true", help="Check rendered opacity or typing effects using hidden Metal windows")
    parser.add_argument("--headful", action="store_true", help="Render in the current desktop, including an isolated Linux virtual display")
    parser.add_argument("--scenario", choices=("startup", "close-pane", "close-tab", "shell-exit"), default="startup")
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
    for kind in ("STATE", "CONFIG", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    env["GRAFFITTY_TEST_REPORT"] = str(directory / "result.json")
    env["GRAFFITTY_TEST_SCENARIO"] = args.scenario
    shell_process = None
    if os.name == "nt" and args.scenario != "startup":
        env["GRAFFITTY_TEST_PROCESS_RECEIPT"] = str(directory / "process-retained")
    launch_directory = directory / "gui-launch"
    configured_directory = directory / "configured-start"
    launch_directory.mkdir()
    configured_directory.mkdir()
    expected_directory = (configured_directory if args.cwd_mode == "configured" else launch_directory).resolve()
    env["GRAFFITTY_INITIAL_PWD"] = str(launch_directory.resolve())
    env["GRAFFITTY_TEST_EXPECTED_CWD"] = str(expected_directory)
    env.pop("LOCAL_STARTUP_TEST_ENV", None)
    shell_evidence = directory / "configured-shell-start.log"
    shell = directory / ("configured-shell.ps1" if os.name == "nt" else "configured-shell")
    if os.name == "nt":
        shell.write_text("Add-Content -LiteralPath '" + str(shell_evidence).replace("'", "''") +
                         "' -Value 'configured-shell'\nfunction prompt { 'READY> ' }\n", encoding="utf-8")
        shell_command = [shutil.which("pwsh.exe") or "pwsh.exe", "-NoLogo", "-NoProfile", "-NoExit", "-File", str(shell)]
    else:
        shell.write_text("#!/bin/sh\nprintf '%s\\n' configured-shell >> " + shlex.quote(str(shell_evidence)) + "\nexec /bin/sh \"$@\"\n")
        shell.chmod(0o700)
        shell_command = [str(shell)]
    config = directory / "config/graffitty"
    config.mkdir(parents=True)
    (config / "client.toml").write_text('[terminal.background]\nalpha = 0.85\n')
    (config / "server.toml").write_text(
        '[terminal]\nlogin_shell = false\nshell_integration = false\n'
        'shell = ' + json.dumps(shell_command) + '\n'
        '[terminal.environment]\nLOCAL_STARTUP_TEST_ENV = "configured-value"\n'
    )
    with PrivateServer(env, directory, None) as owner:
        graphics = ([] if os.name == "nt" or args.headful else prepare_background(env, directory / "guard")) if args.gpu else ["--headless"]
        with (directory / "godot.log").open("w") as log:
            result = subprocess.Popen([args.godot, *graphics, "--path", str(ROOT / "frontends/godot/project"),
                "--script", "res://tests/" + ("local_startup_smoke.gd" if args.scenario == "startup" else "local_workspace_smoke.gd"), "--", "--no-plugin", *(["--cwd=" + str(configured_directory)] if args.cwd_mode == "configured" else [])],
                env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                if "GRAFFITTY_TEST_PROCESS_RECEIPT" in env:
                    from windows_relaunch_e2e import ProcessHandle
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline and result.poll() is None:
                        try:
                            initial = json.loads((directory / "result.json").read_text(encoding="utf-8"))
                        except (OSError, ValueError):
                            time.sleep(.02)
                            continue
                        if initial.get("shell_pid", 0) > 0:
                            shell_process = ProcessHandle(initial["shell_pid"])
                            (directory / "shell-identity.json").write_text(json.dumps({"pid": shell_process.pid, "birth": shell_process.birth}))
                            Path(env["GRAFFITTY_TEST_PROCESS_RECEIPT"]).write_text("ready")
                            break
                    assert shell_process is not None, "No live shell identity captured"
                result.wait(timeout=60)
            except BaseException:
                if result.poll() is None:
                    result.kill()
                    result.wait(timeout=10)
                if shell_process: shell_process.cleanup()
                raise
        report = json.loads((directory / "result.json").read_text()) if (directory / "result.json").exists() else {}
        assert result.returncode == 0 and report and not report["failures"], (f"exit=0x{result.returncode & 0xffffffff:08x}", report, (directory / "godot.log").read_text())
        assert "SCRIPT ERROR:" not in (directory / "godot.log").read_text(), (directory / "godot.log").read_text()
        launches = 3 if args.scenario == "startup" else 1
        assert shell_evidence.read_text().splitlines() == ["configured-shell"] * launches, "One shell per fresh launch; reattach and closing must not spawn another shell"
        if args.scenario != "startup":
            assert report.get("close_requested"), "App must exit through the requested close action"
            # Observe the real child before fixture teardown can terminate it.
            report["owner_exit_code"] = owner.process.wait(timeout=5)
            assert report["owner_exit_code"] == 0, "Last session must stop its owner naturally"
            assert not owner.descriptor.exists(), "Closed owner must remove its descriptor"
            if shell_process:
                try:
                    assert shell_process.exited(5000), "Closing the final pane must terminate its original shell"
                finally:
                    shell_process.cleanup()
            else:
                try:
                    os.kill(report["shell_pid"], 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("Closing the final pane must terminate its shell")
        if args.gpu and os.name != "nt" and not args.headful: assert not background_failures(directory / "guard"), background_failures(directory / "guard")
        report.update(scenario=args.scenario, cwd_mode=args.cwd_mode, expected_cwd=str(expected_directory), configured_shell=str(shell), configured_shell_launches=launches)
        (directory / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("LOCAL_STARTUP_E2E_PASS", directory)


if __name__ == "__main__":
    main()
