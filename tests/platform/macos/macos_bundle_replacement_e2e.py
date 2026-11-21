#!/usr/bin/env python3
"""Replace a private running app bundle; cwd queries and new tabs must survive."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import background_failures, prepare_background
from packaged_probe import write_probe

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

PROBE = """
var tree: SceneTree = self
host = await first_host()
if host == null:
	print("BUNDLE_REPLACEMENT_FAIL")
	quit(1)
	return
var first_pid = host.active_terminal().get_shell_pid()
var folder = OS.get_environment("GRAFFITTY_REPLACEMENT_EVIDENCE")
FileAccess.open(folder.path_join("ready"), FileAccess.WRITE).store_string(str(first_pid))
while not FileAccess.file_exists(folder.path_join("replaced")):
	await tree.process_frame
var expected = OS.get_environment("GRAFFITTY_INITIAL_PWD")
var valid = host._local_directory(expected) == expected
var process_directory = DirAccess.open(".")
valid = valid and process_directory != null and process_directory.get_current_dir() == "/"
valid = valid and host.terminal_start_directory() == expected
if valid:
	host.create_session()
	var deadline = Time.get_ticks_msec() + 15000
	while (host.get_tabs().size() < 2 or host.active_terminal() == null or host.active_terminal().get_shell_pid() <= 0 or host.active_terminal().get_shell_pid() == first_pid) and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	valid = host.get_tabs().size() == 2 and host.active_terminal() != null and host.active_terminal().get_shell_pid() > 0 and host.active_terminal().get_shell_pid() != first_pid
if valid:
	var receipt = folder.path_join("shell-pwd")
	host.active_terminal().send_text("pwd -P > '" + receipt.replace("'", "'\\\"'\\\"'") + "'\\n")
	var deadline = Time.get_ticks_msec() + 5000
	while (not FileAccess.file_exists(receipt) or FileAccess.get_file_as_string(receipt).is_empty()) and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	valid = FileAccess.get_file_as_string(receipt).strip_edges() == expected
var report = {"passed": valid, "original_pid": first_pid, "tabs": host.get_tabs().size()}
FileAccess.open(folder.path_join("result.json"), FileAccess.WRITE).store_string(JSON.stringify(report))
print("BUNDLE_REPLACEMENT_PASS" if valid else "BUNDLE_REPLACEMENT_FAIL")
tree.quit(0 if valid else 1)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    source = args.app.resolve()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(evidence / kind.lower())
    launch = evidence / "shell-directory"
    launch.mkdir()
    env["GRAFFITTY_INITIAL_PWD"] = str(launch)
    env["GRAFFITTY_REPLACEMENT_EVIDENCE"] = str(evidence)
    # The probe stays outside both bundles, which are replaced under it.
    probe = write_probe(evidence / "replacement-probe.gd", PROBE)
    os.environ["GRAFFITTY_TEST_SERVER"] = str(source / "Contents/Resources/graffitty/tools/gft")
    with tempfile.TemporaryDirectory(prefix="graffitty-replacement-", suffix=".noindex") as temporary:
        directory = Path(temporary)
        app = directory / "Graffitty.app"
        replacement = directory / "replacement/Graffitty.app"
        replacement.parent.mkdir()
        for target in (app, replacement):
            subprocess.run(["cp", "-cR", str(source), str(target)], check=True)
        # Release templates ignore --script. Attach the probe to the running
        # SceneTree through an autoload in these disposable app copies only.
        # The app still boots its own main scene, exactly once.
        bootstrap = evidence / "probe-autoload.gd"
        bootstrap.write_text(
            'extends Node\nfunc _ready():\n\tget_tree().set_script(load('
            + json.dumps(str(probe))
            + '))\n\tget_tree().probe.call_deferred()\n'
        )
        for target in (app, replacement):
            override = target / "Contents/MacOS/override.cfg"
            assert not override.exists(), "Candidate must not contain a test override"
            override.write_text('[autoload]\nPackagedProbe=' + json.dumps('*' + str(bootstrap)) + '\n')
        graphics = prepare_background(env, evidence / "guard")
        wrapper = evidence / "runtime"
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(app / "Contents/MacOS/GraffittyRuntime")) + ' ' + shlex.join(graphics) + ' "$@"\n')
        wrapper.chmod(0o755)
        env["GRAFFITTY_GODOT"] = str(wrapper)
        try:
            with PrivateServer(env, evidence, "/bin/sh"), (evidence / "godot.log").open("w") as log:
                process = subprocess.Popen([str(app / "Contents/MacOS/Graffitty"), "--", "--shell=/bin/sh", "--cwd=" + str(launch)], cwd=launch, env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 30
                    while not (evidence / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(.02)
                    assert (evidence / "ready").exists(), "Runtime did not reach the live workspace"
                    subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)
                    subprocess.run([LSREGISTER, "-u", str(replacement)], capture_output=True)
                    rename = ctypes.CDLL(None, use_errno=True).renamex_np
                    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
                    rename.restype = ctypes.c_int
                    if rename(os.fsencode(app), os.fsencode(replacement), 2) != 0:
                        error = ctypes.get_errno()
                        raise OSError(error, os.strerror(error))
                    shutil.rmtree(replacement)
                    (evidence / "replaced").touch()
                    process.wait(timeout=30)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
            output = (evidence / "godot.log").read_text()
            assert process.returncode == 0 and "BUNDLE_REPLACEMENT_PASS" in output and "ERROR:" not in output, output
            assert json.loads((evidence / "result.json").read_text())["passed"]
            assert not background_failures(evidence / "guard"), background_failures(evidence / "guard")
        finally:
            for bundle in directory.rglob("*.app"):
                subprocess.run([LSREGISTER, "-u", str(bundle)], capture_output=True)
    print("MACOS_BUNDLE_REPLACEMENT_PASS", evidence)


if __name__ == "__main__":
    main()
