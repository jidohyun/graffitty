"""Real embedded Chromium: package self-import under Node/Bun + Playwright Test.
No chromium download, replacement chromium, external services, or test-only CDP port.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[2]
sys.path.insert(0, str(ROOT / "tests/support"))
from e2e_background import prepare_background, background_failures
from e2e_server import PrivateServer


def main():
    subprocess.run(["npm", "run", "build"], cwd=PACKAGE, check=True)
    # The terminal holder's Unix socket lives below this directory; macOS's
    # default per-user temp path is too long for sockaddr_un (SUN_LEN).
    directory = Path(tempfile.mkdtemp(prefix="gpw-e2e-", dir="/tmp" if sys.platform != "win32" else None))
    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<!doctype html><title>Owned test page</title><h1>Graffitty</h1>")
        def log_message(self, *_args):
            pass
    web = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=web.serve_forever, daemon=True).start()
    env = {**{key: value for key, value in os.environ.items() if not key.startswith(("GRAFFITTY_",))}, "GRAFFITTY_PLAYWRIGHT_TEST_DIR": str(directory),
           "GRAFFITTY_PLAYWRIGHT_TEST_URL": f"http://127.0.0.1:{web.server_port}/"}
    for kind in ("STATE", "CONFIG", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
    # Exercise the ordinary frontend and a separately owned private server.
    env.pop("GODOT_CHROMIUM_HOST", None)
    log = (directory / "host.log").open("w")
    owner = PrivateServer(env, directory, "/bin/sh")
    owner.__enter__()
    host = None

    try:
        background = prepare_background(env, directory / "background")
        host = subprocess.Popen(["godot", *background, "--path", str(ROOT / "frontends/godot/project"),
            "--script", "res://tests/playwright_attachment_host.gd", "--", "--shell=/bin/sh"],
            env=env, stdout=log, stderr=log)
        until = time.monotonic() + 45
        while not (directory / "ready.json").exists():
            if host.poll() is not None or time.monotonic() > until:
                raise RuntimeError("Host did not become ready: " + (directory / "host.log").read_text())
            time.sleep(.1)
        ready = json.loads((directory / "ready.json").read_text())
        env.update(ready["env"])
        env["GRAFFITTY_CHROMIUM"] = ready["chromium"]
        env["GRAFFITTY_FOREIGN_TEST_TOKEN"] = ready["foreign_token"]
        subprocess.run(["node", "tests/authorization.mjs"], cwd=PACKAGE, env=env, check=True, timeout=30)
        subprocess.run(["node", "tests/background.mjs"], cwd=PACKAGE, env=env, check=True, timeout=45)
        for runtime in ["node", "bun"]:
            if not shutil.which(runtime):
                raise RuntimeError(f"{runtime} is required for this compatibility test")
            subprocess.run([runtime, "tests/client.mjs"], cwd=PACKAGE, env=env, check=True, timeout=60)
        subprocess.run(["node", "tests/launch.mjs"], cwd=PACKAGE, env=env, check=True, timeout=60)
        subprocess.run(["node", "node_modules/@playwright/test/cli.js", "test", "--config", "tests/playwright.config.ts"], cwd=PACKAGE, env=env, check=True, timeout=60)
        subprocess.run(["node", "tests/authorization.mjs", "revoke"], cwd=PACKAGE, env=env, check=True, timeout=30)
        (directory / "done").touch()
        host.wait(timeout=25)
        output = (directory / "host.log").read_text()
        if host.returncode or "PLAYWRIGHT_ATTACHMENT_HOST_REPLAY_PASS" not in output:
            raise RuntimeError(output)
        guard_errors = background_failures(directory / "background", host.pid)
        if guard_errors: raise RuntimeError("; ".join(guard_errors))
        print(output)
        print(f"PASS: real Graffitty attachment E2E. Artifacts: {directory}")
    finally:
        (directory / "done").touch()
        if host is not None and host.poll() is None:
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.terminate()
                host.wait(timeout=10)
        owner.__exit__(None, None, None)
        web.shutdown()
        web.server_close()
        log.close()
        print(f"Artifacts: {directory}")


if __name__ == "__main__":
    main()
