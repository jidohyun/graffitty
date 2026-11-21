#!/usr/bin/env python3
"""Record the castle demo with private shell fixtures and real replay inputs."""
import argparse
import importlib.machinery
import importlib.util
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
sys.path.insert(0, str(ROOT / "videos/shared"))
import shlex
import shutil
import subprocess
import threading
import uuid

from demo_container import build_image
from av1 import check_encoder, probe_av1
from e2e_background import prepare_background, clear_background, background_failures
from e2e_server import PrivateServer

loader = importlib.machinery.SourceFileLoader("record_effects", str(ROOT / "videos/effects/recording/record.py"))
effects = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(effects)


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", default="localhost/graffitty-effects:4")
    parser.add_argument("--connection", default=None)
    parser.add_argument("--godot", default=shutil.which("godot"))
    parser.add_argument("--build-image", action="store_true")
    parser.add_argument("--local-shell", action="store_true", help="Use a private local zsh fixture when Podman is unavailable")
    parser.add_argument("--filetree-only", action="store_true", help="Rehearse the filetree continuation")
    parser.add_argument("--chromium-only", action="store_true", help="Rehearse Markdown and agent chromium chapters")
    if os.name == "nt":
        parser.add_argument("--opening-only", action="store_true", help="Record the Castle workspace opening")
        parser.add_argument("--reimport-resources", action="store_true", help="Refresh the Windows recording resource cache")
    args = parser.parse_args()
    if os.name == "nt":
        # The approved main replay already owns Castle placement and effects.
        # Use its native PowerShell fixtures and chapter assertions on Windows.
        sys.path.insert(0, str(ROOT / "videos/main-demo/recording/tiling"))
        from record_windows import record
        args.castle = True
        args.capture_from_filetree = False
        args.filetree_transition_only = False
        args.through_filetree = False
        return record(args, effects)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    podman = [shutil.which("podman")]
    if args.connection:
        podman += ["--connection", args.connection]
    if args.build_image and not args.local_shell:
        build_image(podman, args.image)
    if not args.local_shell:
        run([*podman, "image", "exists", args.image])
    name = "graffitty-tiling-" + uuid.uuid4().hex[:12]
    host_workspace = Path("/Users/Shared/demo-workspace")
    host_demo = host_workspace / "demo"
    created_host_demo = False
    shared_demo = host_demo
    runtime = Path("/tmp") / name
    runtime.symlink_to(output, target_is_directory=True)
    container_created = False
    web_server = None
    try:
        if not args.local_shell:
            if host_workspace.exists() or host_workspace.is_symlink():
                raise RuntimeError("The isolated recording needs an unused " + str(host_workspace))
            shared_demo.mkdir(parents=True)
            created_host_demo = True
            run([*podman, "run", "-d", "--name", name, "--network=none",
                 "--volume", str(shared_demo) + ":/home/demo", "--workdir", "/home/demo", args.image], stdout=subprocess.DEVNULL)
            container_created = True
            run([*podman, "exec", name, "useradd", "--no-create-home", "--home-dir", "/home/demo", "demo"])
        shell = output / "shell.sh"
        if args.local_shell:
            for program in ["zsh", "git"]:
                if not shutil.which(program):
                    raise RuntimeError(program + " is required for the local fixture")
            fixture = output / "fixture"
            fixture.mkdir()
            shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/zshrc", fixture / ".zshrc")
            shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/main.py", fixture / "main.py")
            shutil.copyfile(ROOT / "videos/main-demo/assets/fixtures/layout.png", fixture / "layout.png")
            shutil.copyfile(ROOT / "apps/server/shell-integration/integration.sh", fixture / "integration.sh")
            demo = output / "demo"
            run(["/bin/sh", ROOT / "videos/main-demo/recording/tiling/setup.sh", demo, fixture])
            shell.write_text("#!/bin/sh\ncd " + shlex.quote(str(demo)) + "\nexec " + shlex.join([
                "/usr/bin/env", "ZDOTDIR=" + str(fixture), "/bin/zsh", "-d", "-i"]) + "\n")
        else:
            if not host_demo.exists():
                host_demo.mkdir()
                created_host_demo = True
            if not host_demo.is_dir():
                raise RuntimeError("The recording working directory must be a directory: " + str(host_demo))
            demo = host_demo
            run([*podman, "exec", name, "mkdir", "-p", "/opt/tiling"])
            run([*podman, "cp", ROOT / "apps/server/terminfo/xterm-ghostty.terminfo", name + ":/tmp/xterm-ghostty.terminfo"])
            run([*podman, "exec", name, "tic", "-x", "/tmp/xterm-ghostty.terminfo"])
            run([*podman, "cp", ROOT / "videos/main-demo/recording/tiling/zshrc", name + ":/opt/tiling/.zshrc"])
            run([*podman, "cp", ROOT / "videos/main-demo/recording/tiling/main.py", name + ":/opt/tiling/main.py"])
            run([*podman, "cp", ROOT / "videos/main-demo/assets/fixtures/layout.png", name + ":/opt/tiling/layout.png"])
            run([*podman, "cp", ROOT / "apps/server/shell-integration/integration.sh", name + ":/opt/tiling/integration.sh"])
            run([*podman, "cp", ROOT / "videos/main-demo/recording/tiling/setup.sh", name + ":/opt/tiling/setup.sh"])
            run([*podman, "exec", name, "/bin/sh", "/opt/tiling/setup.sh", "/home/demo", "/opt/tiling"])
            run([*podman, "exec", name, "chown", "-R", "demo:demo", "/home/demo"])
            # The app uses a private XDG directory; Podman still needs the host's
            # connection configuration when launched from a terminal session.
            podman_config = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
            shell.write_text("#!/bin/sh\nexec " + shlex.join([
                "/usr/bin/env", "XDG_CONFIG_HOME=" + podman_config,
                *podman, "exec", "-it", "-e", "ZDOTDIR=/opt/tiling", name, "runuser", "-u", "demo", "--", "/bin/zsh", "-d", "-i"]) + "\n")
        if not args.local_shell:
            run([*podman, "cp", name + ":/opt/fast-syntax-highlighting", output / "fast-syntax-highlighting"])
        host_fixture = runtime / "host-shell"
        host_fixture.mkdir()
        shutil.copyfile(ROOT / "apps/server/shell-integration/integration.sh", host_fixture / "integration.sh")
        host_rc = (ROOT / "videos/main-demo/recording/tiling/zshrc").read_text().replace(
            "/opt/fast-syntax-highlighting", str(runtime / "fast-syntax-highlighting"))
        host_rc += '\nnvim() { NVIM_APPNAME=nvim-graffitty-demo command nvim "$@"; }\n'
        for provider in ["claude", "codex"]:
            host_rc += provider + '() { command "$GRAFFITTY_BIN" dev ' + provider + '-mock --config "$DEMO_RUNTIME/' + provider + '.json"; }\n'
        (host_fixture / ".zshrc").write_text(host_rc)
        original = shell.read_text().removeprefix("#!/bin/sh\n")
        shell.write_text("#!/bin/sh\nif test -f " + shlex.quote(str(runtime / "host-mode")) + "; then\n"
                         + "cd " + shlex.quote(str(demo)) + "\nexec " + shlex.join([
                             "/usr/bin/env", "ZDOTDIR=" + str(host_fixture), "/bin/zsh", "-d", "-i"])
                         + "\nfi\n" + original)
        shell.chmod(0o700)
        project = effects.stage_project(output, "2400x1500")
        (project / "llm-e2e").symlink_to(ROOT / "tests/llm-e2e", target_is_directory=True)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))}
        clear_background(env)
        env.update(XDG_CONFIG_HOME=str(runtime / "config"), XDG_STATE_HOME=str(runtime / "state"),
                   XDG_DATA_HOME=str(runtime / "data"), XDG_CACHE_HOME=str(runtime / "cache"),
                   GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_MOVIE_PAUSED="1",

                   GRAFFITTY_AV1_CRF="15", GRAFFITTY_AV1_PRESET="8")
        castle_config = runtime / "config/graffitty/client.toml"
        castle_config.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/castle-client.toml", castle_config)
        env["DEMO_RUNTIME"] = str(runtime)
        bin_dir = runtime / "bin"
        bin_dir.mkdir()
        (bin_dir / "gft").symlink_to(Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/release/gft")))
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        markdown_config = runtime / "config/nvim-graffitty-demo"
        markdown_config.mkdir(parents=True)
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/markdown-init.lua", markdown_config / "init.lua")
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/guide.md", runtime / "guide.md")
        for plugin in ["live-server.nvim", "markdown-preview.nvim"]:
            shutil.copytree(Path.home() / ".local/share/nvim/lazy" / plugin, runtime / "plugins" / plugin,
                            ignore=shutil.ignore_patterns(".git"))
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_):
                pass
        web_server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(ROOT / "videos/main-demo/recording/tiling")))
        threading.Thread(target=web_server.serve_forever, daemon=True).start()
        run([sys.executable, ROOT / "videos/main-demo/recording/tiling/scenarios.py", runtime,
             "http://127.0.0.1:" + str(web_server.server_port)])
        # The server runs the bundled, sandboxed filetree: no plugin download to prepare.
        if not (ROOT / "dist/filetree/manifest.json").is_file():
            raise SystemExit("Run tools/build_filetree_runtime.py before recording")
        # Terminal settings and Flat effects come directly from app defaults.
        # Only the recording backdrop replaces native desktop composition.
        command = [args.godot, *prepare_background(env, output), "--path", str(project),
                   "--language", "en",
                   "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                   "--quit-after", "36000", "--script", "res://videos/main-demo/recording/castle/CastlePreview.gd", "--",
                   "--record", "--tabs=1", "--shell=" + str(shell), "--cwd=" + str(demo),
                   "--plugin=edinburgh-castle", "--world=3d", "--opacity=1",
                   "--no-focus-skip",
                   "--demo-output=" + str(output), "--demo-directory=" + str(demo)]
        if args.filetree_only:
            command.append("--filetree-only")
        if args.chromium_only:
            command.append("--chromium-only")
        (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        with PrivateServer(env, output, str(shell)):
            with (output / "godot.log").open("w") as log:
                run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        if not (output / "capture.json").is_file():
            raise RuntimeError("Recording ended before the replay; inspect godot.log and session-owner/server.log")
        metadata = json.loads((output / "capture.json").read_text())
        metadata["shell_backend"] = "local" if args.local_shell else "podman"
        metadata["working_directory"] = "/home/demo" if not args.local_shell else str(demo)
        metadata["connected_chapters_directory"] = str(demo)
        metadata["recording_backdrop"] = "#4a4d54"
        metadata["filetree_setup"] = "bundled init.lua and plugins prepared before recording"
        if not args.local_shell:
            metadata["podman_connection"] = args.connection or "default"
            metadata["podman_image"] = args.image
        (output / "capture.json").write_text(json.dumps(metadata, indent=2) + "\n")
        errors = metadata["failures"] + background_failures(output)
        if errors:
            raise RuntimeError(str(errors))
        log = (output / "godot.log").read_text()
        if "RECORDTILINGDEMO_REPLAY_PASS" not in log:
            raise RuntimeError("Replay did not pass; inspect godot.log")
        probe, stream = probe_av1(output / "footage.mp4")
        if [stream["width"], stream["height"]] != [2400, 1500]:
            raise RuntimeError("Incorrect recording size")
        if abs(int(stream["nb_read_frames"]) - metadata["frames"]) > 1:
            raise RuntimeError("Capture and encoded frame counts differ")
        (output / "probe.json").write_text(json.dumps(probe, indent=2) + "\n")
        print(output / "footage.mp4")
    finally:
        if web_server is not None:
            web_server.shutdown()
            web_server.server_close()
        if container_created:
            run([*podman, "rm", "-f", name], stdout=subprocess.DEVNULL)
        if created_host_demo:
            try:
                shutil.copytree(host_demo, output / "demo")
                shutil.rmtree(host_workspace)
            except FileNotFoundError:
                pass
        runtime.unlink()


if __name__ == "__main__":
    main()
