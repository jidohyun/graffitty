#!/usr/bin/env python3
"""Run CLI/MCP PTY fixtures through a real Godot adapter and private session owner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import prepare_background


def private_chromium_guard(env, directory):
    """Arm only the CEF UI host, never its owning server, PTYs or helpers."""
    if sys.platform != "darwin":
        return
    target = ROOT / "dist" / (ROOT / "dist/chromium-host-path.txt").read_text().strip()
    guard_env = {}
    evidence = directory / "chromium-native"
    prepare_background(guard_env, evidence)
    launcher = directory / "chromium-host"
    launcher.write_text("#!/usr/bin/env python3\nimport os, sys\n"
        + f"os.environ.update({guard_env!r})\n"
        + f"os.environ['GRAFFITTY_E2E_NATIVE_REPORT'] = {str(evidence)!r} + '/native-' + str(os.getpid()) + '.json'\n"
        + f"os.execv({str(target)!r}, [{str(target)!r}] + sys.argv[1:])\n")
    launcher.chmod(0o700)
    env["GRAFFITTY_CHROMIUM_HOST"] = str(launcher)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=ROOT / "target/debug/gft")
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    os.environ["GRAFFITTY_TEST_SERVER"] = str(args.server.resolve())
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))
           and k not in ("CODEX_THREAD_ID", "CODEX_SESSION_ID")}
    for kind in ("STATE", "DATA", "CONFIG", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    env.update(GRAFFITTY_CLIENT_TEST_DIR=str(directory), GRAFFITTY_CLIENT_TEST_REPO=str(ROOT))
    private_chromium_guard(env, directory)
    result = {"status": "FAIL", "server_sha256": hashlib.sha256(args.server.read_bytes()).hexdigest()}
    with PrivateServer(env, directory, "/bin/sh"):
        with (directory / "host.log").open("w") as log:
            child = subprocess.Popen(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                "--script", "res://tests/client_smoke_host.gd", "--", "--shell=/bin/sh"],
                env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = child.wait(timeout=210)
            except subprocess.TimeoutExpired:
                child.terminate()
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=10)
                code = -1
        output = (directory / "host.log").read_text()
        result.update(exit_code=code, status="PASS" if code == 0 and "CLIENT_SMOKE_HOST_REPLAY_PASS" in output else "FAIL")
        for fixture in ("agent", "terminal"):
            path = directory / f"{fixture}.json"
            if path.exists(): result[fixture] = json.loads(path.read_text())
    if sys.platform == "darwin":
        reports = [json.loads(path.read_text()) for path in (directory / "chromium-native").glob("native-*.json")]
        result["chromium_background"] = reports
        if not reports or any(r.get("samples", 0) < 10 or r.get("visible_samples") != 0
                              or r.get("active_samples") != 0 for r in reports):
            result["status"] = "FAIL"
    (directory / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return result["status"] != "PASS"

if __name__ == "__main__":
    raise SystemExit(main())
