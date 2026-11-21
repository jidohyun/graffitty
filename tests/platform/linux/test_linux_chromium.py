#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2"]
# ///
"""Linux Chromium native + Android matrix. Requires built Linux and Android artifacts.

SSH selects the Linux machine; --exec-prefix optionally enters a container.
The advertised WebSocket URL must be reachable directly from the tablet.
Owns disposable servers/profiles and the runtime-test APK, never production data.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import time
import traceback
import uuid

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/android",)]
import test_android_runtime as android

ROOT = Path(__file__).resolve().parents[3]
CASES = ["hardware-backend", "navigation", "touch", "scroll-stability", "resume", "crash-recovery", "url", "clipboard"]


class Matrix:
    def __init__(self, args):
        self.args = args
        self.prefix = shlex.split(args.exec_prefix)
        self.adb = ["adb", "-s", args.adb]
        self.output = args.artifacts.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.remote = PurePosixPath(args.repo) / ".cache/linux-chromium-e2e" / uuid.uuid4().hex
        self.results = {}
        self.apk_identity = None
        self.device_apk = "/data/local/tmp/graffitty-linux-e2e-" + uuid.uuid4().hex + ".apk"

    def command(self, *words):
        return ["ssh", self.args.ssh, shlex.join(self.prefix + [str(w) for w in words])]

    def call(self, *words, **kwargs):
        return subprocess.run(self.command(*words), check=True, timeout=kwargs.pop("timeout", 60), **kwargs)

    def deploy(self):
        for source in [ROOT / "tests/platform/linux/linux_chromium_fixture.py", ROOT / "tests/chromium/chromium_linux_backend_e2e.py",
                       ROOT / "tests/chromium/chromium_native_backend_e2e.py"]:
            self.call("python3", "-c", "import os,sys;from pathlib import Path;os.umask(0o077);p=Path(sys.argv[1]);p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(sys.stdin.buffer.read())",
                      self.remote / source.name, input=source.read_bytes(), capture_output=True)

    def install(self, adb, apk):
        stat = apk.stat()
        identity = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        if identity != self.apk_identity:
            android.run(adb + ["push", "-Z", str(apk), self.device_apk], capture_output=True, timeout=android.INSTALL_TIMEOUT)
            self.apk_identity = identity
        result = android.run(adb + ["shell", "pm", "install", "-r", self.device_apk], capture_output=True, timeout=android.INSTALL_TIMEOUT)
        assert b"Success" in result.stdout, result.stdout

    def record(self, name, action):
        directory = self.output / name
        directory.mkdir()
        try:
            action(directory)
            self.results[name] = {"status": "pass"}
        except Exception as error:
            (directory / "failure.txt").write_text(traceback.format_exc())
            self.results[name] = {"status": "fail", "reason": str(error)}
        (self.output / "results.json").write_text(json.dumps(self.results, indent=2))
        print(name, self.results[name]["status"], flush=True)

    def native(self, platform, backend, output):
        remote_output = self.remote / output.name
        try:
            with (output / "native.log").open("wb") as log:
                self.call("python3", self.remote / "chromium_linux_backend_e2e.py", "--host", self.args.host,
                          "--capture-library", self.args.capture_library, "--platform", platform,
                          "--backend", backend, "--artifacts", remote_output, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        finally:
            with (output / "native-artifacts.tar.gz").open("wb") as archive:
                collected = subprocess.run(self.command("tar", "-C", remote_output, "-czf", "-", "."),
                                           stdout=archive, stderr=subprocess.PIPE, timeout=60)
            if collected.returncode:
                (output / "archive-error.txt").write_bytes(collected.stderr)
        assert collected.returncode == 0, "Native evidence archive could not be collected"

    def resources(self, output):
        with (output / "resources.log").open("wb") as log:
            self.call("cargo", "test", "--locked", "--manifest-path", PurePosixPath(self.args.repo) / "Cargo.toml",
                      "-p", "terminal-resource-monitor", "linux::tests", "--", "--include-ignored",
                      stdout=log, stderr=subprocess.STDOUT, timeout=600)

    def client(self, platform, backend, case, output):
        remote_output = self.remote / output.name
        helper = self.remote / "linux_chromium_fixture.py"
        with (output / "launcher.log").open("wb") as log:
            launcher = subprocess.Popen(self.command("python3", helper, "serve", "--directory", remote_output,
                "--server", self.args.server, "--host", self.args.host, "--platform", platform,
                "--backend", backend, "--listen", self.args.listen), stdout=log, stderr=log)
            try:
                for _ in range(120):
                    descriptor = subprocess.run(self.command("cat", remote_output / "connection.json"), capture_output=True, timeout=15)
                    if descriptor.returncode == 0:
                        break
                    assert launcher.poll() is None, "Linux fixture exited before publishing a connection"
                    time.sleep(.25)
                else:
                    raise TimeoutError("Linux fixture startup timed out")
                (output / "connection.json").write_bytes(descriptor.stdout)
                connection = json.loads(descriptor.stdout)["remote"]
                connection["url"] = self.args.url
                config = {"connection": connection, "scenario": "workspace", "case": "chromium-" + case}

                def kill(host, kind):
                    result = self.call("python3", helper, "kill", "--directory", remote_output,
                                      "--host-pid", host, "--kind", kind, capture_output=True)
                    with (output / "crash-actions.jsonl").open("ab") as actions:
                        actions.write(result.stdout)

                android.smoke(self.adb, output, config=config, record=False, stop_chromium=kill, install_apk=self.install)
            finally:
                try:
                    self.call("touch", remote_output / "stop", capture_output=True)
                    launcher.wait(timeout=30)
                except BaseException:
                    launcher.terminate()
                    launcher.wait(timeout=10)
                    raise
                finally:
                    for name in ("server.log", "cleanup.json", "fixture.json"):
                        result = subprocess.run(self.command("cat", remote_output / name), capture_output=True, timeout=30)
                        if result.returncode == 0:
                            (output / name).write_bytes(result.stdout)
            cleanup = json.loads((output / "cleanup.json").read_text())
            assert cleanup["exit"] == 0 and not cleanup["leaked_cgroups"], cleanup

    def run(self):
        self.deploy()
        try:
            if not self.args.skip_resources:
                self.record("linux-resources", self.resources)
            for platform in self.args.platform:
                for backend in self.args.backend:
                    if not self.args.skip_native:
                        self.record(f"{platform}-{backend}-native", lambda out: self.native(platform, backend, out))
                    for case in self.args.case:
                        for attempt in range(1, self.args.repeat + 1):
                            suffix = f"-{attempt}" if self.args.repeat > 1 else ""
                            self.record(f"{platform}-{backend}-{case}{suffix}", lambda out: self.client(platform, backend, case, out))
        finally:
            subprocess.run(self.adb + ["uninstall", android.PACKAGE], capture_output=True, timeout=30)
            subprocess.run(self.adb + ["shell", "rm", "-f", self.device_apk], capture_output=True, timeout=30)
        return 1 if any(r["status"] != "pass" for r in self.results.values()) else 0


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh", required=True, help="SSH host/alias for Linux")
    parser.add_argument("--exec-prefix", default="", help="Optional command inside SSH, e.g. container-enter")
    parser.add_argument("--repo", required=True, help="Absolute Linux checkout path containing current resource-monitor sources")
    parser.add_argument("--server", required=True, help="Absolute Linux gft binary path")
    parser.add_argument("--host", required=True, help="Absolute Linux Chromium host path")
    parser.add_argument("--capture-library", required=True, help="Absolute Linux capture-test library path")
    parser.add_argument("--adb", required=True, help="Explicit tablet serial")
    parser.add_argument("--url", required=True, help="Authenticated WebSocket URL reachable from the tablet")
    parser.add_argument("--listen", default="127.0.0.1:41817", help="Linux fixture listen address")
    parser.add_argument("--platform", action="append", choices=["wayland", "x11"])
    parser.add_argument("--backend", action="append", choices=["chrome", "alloy"])
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--repeat", type=int, default=1, help="Android repetitions, each with separate evidence")
    parser.add_argument("--skip-native", action="store_true")
    parser.add_argument("--skip-resources", action="store_true")
    parser.add_argument("--artifacts", type=Path, required=True, help="Fresh local directory for private evidence")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    for name in ("repo", "server", "host", "capture_library"):
        if not PurePosixPath(getattr(args, name)).is_absolute():
            parser.error(f"--{name.replace('_', '-')} must be absolute")
    args.platform = args.platform or ["wayland", "x11"]
    args.backend = args.backend or ["chrome", "alloy"]
    args.case = args.case or CASES
    for name in ("platform", "backend", "case"):
        values = getattr(args, name)
        if len(values) != len(set(values)):
            parser.error(f"duplicate --{name}; use --repeat for stability checks")
    raise SystemExit(Matrix(args).run())


if __name__ == "__main__":
    main()
