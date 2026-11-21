#!/usr/bin/env python3
"""Exercise the language chooser and real authenticated server language handoff."""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_background import prepare_background
from e2e_server import PrivateServer
from test_session_transfer import Peer


def main():
    output = Path(tempfile.mkdtemp(prefix="graffitty-localization-"))
    print("Evidence:", output, flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(output / kind.lower())
    env["GRAFFITTY_LOCALIZATION_TEST_OUTPUT"] = str(output)
    args = prepare_background(env, output / "native") if "--gpu" in sys.argv else ["--headless"]
    with (output / "godot.log").open("w") as log:
        result = subprocess.run(["godot", *args, "--path", str(ROOT / "frontends/godot/project"),
                                 "--script", "res://tests/localization_smoke.gd"],
                                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45)
    text = (output / "godot.log").read_text()
    print(text)
    assert result.returncode == 0 and "LOCALIZATION_PASS" in text and "SCRIPT ERROR" not in text

    config = output / "config/graffitty/server.toml"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('# UI language belongs to each client.\n')
    with PrivateServer(env, output, "/bin/sh") as owner:
        peer = Peer(json.loads(owner.descriptor.read_text())["local"], "language", new=True)
        try:
            with (output / "server-client.log").open("w") as log:
                result = subprocess.run(["godot", *args, "--path", str(ROOT / "frontends/godot/project"),
                                         "--script", "res://tests/server_localization_smoke.gd"],
                                        env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
            text = (output / "server-client.log").read_text()
            print(text)
            assert result.returncode == 0 and "SERVER_LOCALIZATION_PASS" in text and "SCRIPT ERROR" not in text
        finally:
            peer.socket.close()


if __name__ == "__main__":
    main()
