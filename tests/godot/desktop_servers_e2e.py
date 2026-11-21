"""Exercise the desktop Servers manager against isolated local and remote owners."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_background import prepare_background, clear_background, background_failures
from e2e_server import PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--gpu", action="store_true")
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    env["GRAFFITTY_TEST_EVIDENCE"] = str(directory)
    descriptor = directory / "remote-owner.json"
    env["GRAFFITTY_TEST_REMOTE_DESCRIPTOR"] = str(descriptor)
    remote_env = env.copy()
    clear_background(remote_env)
    with PrivateServer(env, directory, "/bin/sh") as owner:
        with (directory / "remote-owner.log").open("w") as log:
            remote = subprocess.Popen([str(owner.binary), "server", "--listen", "127.0.0.1:0", "--connection", str(descriptor), "--auth-file", str(directory / "remote-auth.json"), "--shell", "/bin/sh"], env=remote_env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 20
                while not descriptor.exists() and remote.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                assert descriptor.exists(), "Remote owner did not start"
                graphics = prepare_background(env, directory / "guard") if args.gpu else ["--headless"]
                for scenario in ("manager", "startup"):
                    with (directory / f"{scenario}.log").open("w") as frontend_log:
                        result = subprocess.run([os.environ.get("GRAFFITTY_GODOT") or shutil.which("godot"), *graphics, "--path", str(ROOT / "frontends/godot/project"), "--script", "res://tests/desktop_servers_smoke.gd", "--", "--no-plugin", "--shell=/bin/sh", "--scenario=" + scenario], env=env, stdout=frontend_log, stderr=subprocess.STDOUT, timeout=120)
                    output = (directory / f"{scenario}.log").read_text()
                    assert result.returncode == 0 and "DESKTOP_SERVERS_PASS" in output and "SCRIPT ERROR:" not in output and "ERROR:" not in output, output
                if args.gpu:
                    assert not background_failures(directory / "guard")
                (directory / "result.json").write_text(json.dumps({"status": "PASS", "scenarios": ["manager", "startup"]}) + "\n")
                print("PASS: desktop server switching, new windows, recovery, persistence and startup")
            finally:
                remote.terminate()
                try:
                    remote.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    remote.kill()
                    remote.wait(timeout=5)


if __name__ == "__main__":
    main()
