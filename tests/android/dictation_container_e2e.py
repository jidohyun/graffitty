#!/usr/bin/env python3
"""Android mic UI on desktop against Podman servers; never uses real API keys."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
CONFIG_CASES = ("default-disabled", "disabled", "missing-key", "bad-key-401", "bad-key-403", "bad-key-event")

CASES = [(provider, mode, model) for provider, model in (
    ("gemini", "gemini-3.5-transcribe-live"), ("openai", "gpt-live-transcribe"))
    for mode in CONFIG_CASES]
CASES += [("openai", mode, "gpt-live-transcribe") for mode in (
    "success", "early-stop", "cancel", "empty-commit", "failed-event", "disconnect",
    "final-timeout", "setup-timeout", "rate-limit-http", "quota-event", "model-error")]
CASES += [("openai", "success", "gpt-transcribe")]


def wait_file(path, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            return
        time.sleep(.05)
    raise TimeoutError(f"Timed out waiting for {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection", help="Podman connection; preserves the user's default")
    parser.add_argument("--skip-image-build", action="store_true")
    args = parser.parse_args()
    podman = ["podman"] + (["--connection", args.connection] if args.connection else [])
    # Reuse the repository's Rust integration-test image and compiler caches.
    image = "localhost/graffitty-navigation-e2e:1"
    if not args.skip_image_build:
        subprocess.run([*podman, "build", "-t", image, str(ROOT / "tests/containers/navigation")], check=True)
    evidence = Path(tempfile.mkdtemp(prefix="graffitty-dictation-container-"))
    print("Evidence:", evidence, flush=True)
    name = "gft-dictation-e2e-" + uuid.uuid4().hex[:12]
    try:
        subprocess.run([*podman, "run", "-d", "--rm", "--name", name,
            "-p", "127.0.0.1::7183", "-v", str(ROOT) + ":/workspace:ro",
            "-v", "graffitty-navigation-target:/target",
            "-v", "graffitty-navigation-cargo:/usr/local/cargo/registry",
            "-v", "graffitty-navigation-build-cache:/workspace/.cache",
            "-v", str(evidence) + ":/artifacts", "-e", "CARGO_PROFILE_DEV_DEBUG=0",
            image, "sleep", "infinity"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([*podman, "exec", name, "git", "config", "--global", "--add", "safe.directory", "/workspace"], check=True)
        print("Building the container server…", flush=True)
        with (evidence / "build.log").open("w") as log:
            subprocess.run([*podman, "exec", name, "cargo", "rustc", "--locked", "-p", "graffitty-cli", "--bin", "gft",
                "--", "-C", "linker=clang", "-C", "link-arg=-fuse-ld=lld", "-C", "link-arg=-Wl,--threads=1"],
                check=True, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        port = subprocess.check_output([*podman, "port", name, "7183/tcp"], text=True).strip().rsplit(":", 1)[1]
        for provider, mode, model in CASES:
            case = f"{provider}-{model}-{mode}"
            directory = evidence / case
            directory.mkdir()
            enabled = "" if mode == "default-disabled" else f"enabled = {'false' if mode == 'disabled' else 'true'}\n"
            # The live success case exercises the server default with no model override.
            default_model = provider == "openai" and mode == "success" and model == "gpt-live-transcribe"
            model_line = "" if default_model else f'model = "{model}"\n'
            (directory / "server.toml").write_text(
                '[terminal]\nlogin_shell = false\n'
                '[terminal.font]\nfamily = "DejaVu Sans Mono"\n'
                f'[dictation]\n{enabled}provider = "{provider}"\nlanguage = "ko-KR"\n'
                f'[dictation.providers.{provider}]\n{model_line}'
                f'base_url = "http://127.0.0.1:7184/{"v1" if provider == "openai" else "v1beta"}"\n' )
            subprocess.run([*podman, "exec", "-d", name, "python3", "tests/containers/dictation/server.py", f"/artifacts/{case}", mode, provider, model], check=True, stdout=subprocess.DEVNULL)
            try:
                wait_file(directory / "server.json")
                descriptor = json.loads((directory / "server.json").read_text())
                connections = directory / "connections.json"
                connections.write_text(json.dumps({"url": f"ws://127.0.0.1:{port}", "token": descriptor["token"],
                    "workspace": case, "name": case, "remember": False}))
                env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
                for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                    env[f"XDG_{kind}_HOME"] = str(directory / ("client-" + kind.lower()))
                env.update(GRAFFITTY_DICTATION_CASE=mode, GRAFFITTY_DICTATION_PROVIDER=provider,
                    GRAFFITTY_DICTATION_MODEL=model, GRAFFITTY_DICTATION_TYPED=str(directory / "typed.txt"),
                    GRAFFITTY_DICTATION_REMOTE_TYPED=f"/artifacts/{case}/typed.txt", GRAFFITTY_DICTATION_RESULT=str(directory / "result.json"))
                with (directory / "client.log").open("w") as log:
                    result = subprocess.run(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                        "--script", "res://tests/dictation_config_e2e.gd", "--", "--touch-controls",
                        f"--remote-connections={connections}"], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                logs = (directory / "client.log").read_text()
                assert result.returncode == 0 and "DICTATION_CONFIG_PASS" in logs, logs[-12000:]
                assert not any(marker in logs for marker in ("SCRIPT ERROR:", "ERROR:")), logs[-12000:]
                report = json.loads((directory / "result.json").read_text())
                calls = [json.loads(line) for line in (directory / "provider.jsonl").read_text().splitlines()] if (directory / "provider.jsonl").exists() else []
                if mode in ("default-disabled", "disabled", "missing-key"):
                    assert not calls, f"{case}: provider must never be contacted"
                else:
                    connections = [call for call in calls if call["event"] == "connection"]
                    assert len(connections) == 1 and connections[0]["key_is_dummy"], calls
                    assert not any(call["event"] == "fixture-error" for call in calls), calls
                if mode in ("success", "early-stop", "empty-commit", "failed-event", "disconnect", "final-timeout"):
                    commits = [call for call in calls if call["event"] == "commit"]
                    assert len(commits) == 1 and commits[0]["bytes"] % 4800 == 18, calls
                if mode == "cancel":
                    assert not any(call["event"] == "commit" for call in calls), calls
                assert "invalid-test-key" not in json.dumps(report)
                print(f"PASS {case}: {report['message']}", flush=True)
            finally:
                (directory / "stop").touch()
                wait_file(directory / "stopped", 10)
        print("DICTATION_CONTAINER_PASS", flush=True)
    finally:
        subprocess.run([*podman, "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
