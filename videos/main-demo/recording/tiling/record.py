#!/usr/bin/env python3
"""Record the tiling demo with private shell fixtures and real replay inputs."""
import argparse
from contextlib import nullcontext
import importlib.machinery
import importlib.util
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
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
import native_capture

loader = importlib.machinery.SourceFileLoader("record_effects", str(ROOT / "videos/effects/recording/record.py"))
effects = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(effects)


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def verify_typing_phrases():
    """Fail before fixture setup, not minutes into an expensive recording."""
    plans = json.loads((ROOT / "videos/shared/typing/timings.json").read_text(encoding="utf-8"))["phrases"]
    required = set()
    for name in ["RecordTilingDemo.gd", "ChromiumChapters.gd"]:
        source = Path(__file__).with_name(name).read_text(encoding="utf-8")
        texts = re.findall(r'\b(?:human_text|type|command)\("((?:\\.|[^"\\])*)"(?=[,)])', source)
        for text in texts:
            required.update(chunk for chunk in re.split(r'\{[^{}]+\}', text) if chunk)
    missing = required - plans.keys()
    if missing:
        raise ValueError(f"Missing typing schedules {sorted(missing)}; update phrases.json and run videos/shared/typing/build.py")


def main():
    verify_typing_phrases()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", default="localhost/graffitty-effects:4")
    parser.add_argument("--connection", default=None)
    parser.add_argument("--godot", default=shutil.which("godot"))
    parser.add_argument("--build-image", action="store_true")
    parser.add_argument("--local-shell", action="store_true", help="Use a private local zsh fixture when Podman is unavailable")
    parser.add_argument("--windows-shell", choices=("pwsh.exe", "powershell.exe"), default="pwsh.exe", help="Native Windows recording shell (PowerShell 7 or Windows PowerShell 5.1)")
    parser.add_argument("--filetree-only", action="store_true", help="Rehearse the filetree continuation")
    parser.add_argument("--capture-from-filetree", action="store_true", help="Prepare the opening off camera, then record the filetree with the same sessions and panes")
    parser.add_argument("--opening-only", action="store_true", help="Record only the opening workspace chapter")
    parser.add_argument("--reimport-resources", action="store_true", help="Refresh the Windows recording resource cache after changing source assets")
    parser.add_argument("--filetree-transition-only", action="store_true", help="Prepare the workspace off camera; record only the direct sidebar session transition")
    parser.add_argument("--through-filetree", action="store_true", help="Record opening, filetree, and the Markdown session click; reuse cached Chromium from typing")
    parser.add_argument("--chromium-only", action="store_true", help="Rehearse Markdown and agent chromium chapters")
    parser.add_argument("--markdown-transition-only", action="store_true", help="Record Markdown through the sidebar switch to Diagram")
    parser.add_argument("--skip-native-window", action="store_true", help="Rehearse without the native-window capture (the finished demo includes it)")
    parser.add_argument("--reuse-native-window", type=Path, help="Reuse a verified take's external Chromium footage while recording fresh app surroundings")
    parser.add_argument("--reuse-native-scene", type=Path, help="Reuse the complete composited native interval without opening a native window")
    parser.add_argument("--flat", dest="castle", action="store_false", help="Record a separate Flat world variation instead of the approved Castle demo")
    args = parser.parse_args()
    if args.markdown_transition_only:
        args.chromium_only = True
        args.skip_native_window = True
    if args.filetree_transition_only:
        args.through_filetree = True
    if os.name == "nt":
        from record_windows import record
        return record(args, effects)
    output = args.output.resolve()
    if args.reuse_native_scene and not args.reuse_native_window:
        parser.error("--reuse-native-scene requires its --reuse-native-window source")
    output.mkdir(parents=True, exist_ok=False)
    if args.reuse_native_window:
        reused = args.reuse_native_window.resolve()
        accepted = json.loads((reused / "capture.json").read_text())
        if accepted["failures"]:
            raise ValueError("Cannot reuse native-window pixels from a failed take")
        native = accepted["native_window"]
        native["reused_from"] = str(reused.relative_to(ROOT))
        (output / "native-window").mkdir()
        if args.reuse_native_scene:
            shutil.copy2(args.reuse_native_scene, output / "native-scene.mp4")
            native["composited_scene"] = "native-scene.mp4"
        else:
            # Reuse only the external window pixels when the app UI changed.
            # A full cached scene still contains the previous app status bar.
            native.pop("composited_scene", None)
            native.pop("cursor_return_patch", None)
        (output / "reused-native-window.json").write_text(json.dumps(native, indent=2) + "\n")
        for name in ["native-window.mp4", "native-window-shape.png"]:
            shutil.copy2(reused / name, output / name)
    audio_metadata = ROOT / "videos/main-demo/composition/demo-audio.json"
    if audio_metadata.exists():
        shutil.copyfile(audio_metadata, output / "demo-audio.json")
        shutil.copyfile(audio_metadata.with_name("demo-narration.json"), output / "demo-narration.json")
    podman = [shutil.which("podman")]
    if args.connection:
        podman += ["--connection", args.connection]
    if args.build_image and not args.local_shell:
        build_image(podman, args.image)
    if not args.local_shell:
        run([*podman, "image", "exists", args.image])
    name = "graffitty-tiling-" + uuid.uuid4().hex[:12]
    host_workspace = Path("/Users/Shared/gft")
    host_demo = host_workspace / "demo"
    created_host_demo = False
    shared_demo = host_demo
    runtime = Path("/tmp") / name
    runtime.symlink_to(output, target_is_directory=True)
    diagram_directory = Path("/tmp") / (name + "-diagram")
    diagram_created = False
    container_created = False
    web_server = None
    try:
        diagram_directory.mkdir()
        diagram_created = True
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
            for media in ["layout.png", "layout.pdf", "video.webm"]:
                shutil.copyfile(ROOT / "videos/main-demo/assets/fixtures" / media, fixture / media)
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
            for media in ["layout.png", "layout.pdf", "video.webm"]:
                run([*podman, "cp", ROOT / "videos/main-demo/assets/fixtures" / media, name + ":/opt/tiling/" + media])
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
        # Check separately loaded chapters too: Godot can exit successfully
        # while reporting a dependency compile error, minutes into a replay.
        for script in ["RecordTilingDemo.gd", "ChromiumChapters.gd"]:
            checked = run([args.godot, "--headless", "--path", project,
                           "--check-only", "--script", "res://videos/main-demo/recording/tiling/" + script],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            (output / (script + ".check.log")).write_text(checked.stdout)
            if "SCRIPT ERROR" in checked.stdout or "ERROR:" in checked.stdout:
                raise RuntimeError("Recorder syntax check failed: " + script + "\n" + checked.stdout)
        if args.castle:
            castle_config = runtime / "config/graffitty/client.toml"
            castle_config.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/castle-client.toml", castle_config)
        # The native-window segment needs the Chrome runtime style; the Alloy
        # backend hides that control. Pinned so every desktop chapter uses the same
        # backend so takes can be spliced.
        server_config = runtime / "config/graffitty/server.toml"
        server_config.parent.mkdir(parents=True, exist_ok=True)
        server_config.write_text('[chromium]\nbackend = "chrome"\n')
        env["DEMO_RUNTIME"] = str(runtime)
        bin_dir = runtime / "bin"
        bin_dir.mkdir()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        markdown_config = runtime / "config/nvim-graffitty-demo"
        markdown_config.mkdir(parents=True)
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/markdown-init.lua", markdown_config / "init.lua")
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/guide.md", runtime / "guide.md")
        shutil.copyfile(ROOT / "videos/main-demo/recording/tiling/http-request.html", runtime / "http-request-source.html")
        for plugin in ["live-server.nvim", "markdown-preview.nvim"]:
            shutil.copytree(Path.home() / ".local/share/nvim/lazy" / plugin, runtime / "plugins" / plugin,
                            ignore=shutil.ignore_patterns(".git"))
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_):
                pass
        web_server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(ROOT / "videos/main-demo/recording/tiling")))
        threading.Thread(target=web_server.serve_forever, daemon=True).start()
        run([sys.executable, ROOT / "videos/main-demo/recording/tiling/scenarios.py", runtime,
             "http://127.0.0.1:" + str(web_server.server_port), diagram_directory])
        # The server runs the bundled, sandboxed filetree: no plugin download to prepare.
        if not (ROOT / "dist/filetree/manifest.json").is_file():
            raise SystemExit("Run tools/build_filetree_runtime.py before recording")
        # Terminal settings and Flat effects come directly from app defaults.
        # Only the recording backdrop replaces native desktop composition.
        command = [args.godot, *prepare_background(env, output), "--path", str(project),
                   "--language", "en",
                   "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                   "--quit-after", "36000", "--script", "res://videos/main-demo/recording/tiling/RecordTilingDemo.gd", "--",
                   "--record", "--tabs=1", "--shell=" + str(shell), "--cwd=" + str(demo),
                   "--bg=#4a4d54", "--opacity=1",
                   "--no-focus-skip",
                   "--demo-output=" + str(output), "--demo-directory=" + str(demo)]
        if args.castle:
            # Castle is an installed world; expose it in the isolated data folder.
            sys.path.insert(0, str(ROOT / "tests/support"))
            from e2e_bistro import installed_world, link_world
            link_world(runtime / "data", installed_world("edinburgh-castle"))
            command += ["--plugin=edinburgh-castle", "--world=3d"]
        if args.filetree_only:
            command.append("--filetree-only")
        if args.capture_from_filetree:
            command.append("--capture-from-filetree")
        if args.opening_only:
            command.append("--opening-only")
        if args.filetree_transition_only:
            command.append("--filetree-transition-only")
        if args.through_filetree:
            command.append("--through-filetree")
        if args.chromium_only:
            command.append("--chromium-only")
        if args.markdown_transition_only:
            command.append("--markdown-transition-only")
        if args.skip_native_window:
            command.append("--skip-native-window")
        (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        with (nullcontext() if args.reuse_native_window or args.skip_native_window or args.filetree_only or args.through_filetree or args.opening_only else native_capture.capture_app(output)):
            with PrivateServer(env, output, str(shell)) as owner:
                # Shell commands and mocks must use the same build as their server.
                (bin_dir / "gft").symlink_to(owner.binary)
                with (output / "godot.log").open("w") as log:
                    # Movie Maker can render below real time on a busy desktop;
                    # allow the full multi-session capture to finish without a retake.
                    run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=7200)
        if not (output / "capture.json").is_file():
            raise RuntimeError("Recording ended before the replay; inspect godot.log and session-owner/server.log")
        metadata = json.loads((output / "capture.json").read_text())
        metadata["shell_backend"] = "local" if args.local_shell else "podman"
        metadata["working_directory"] = "/home/demo" if not args.local_shell else str(demo)
        metadata["connected_chapters_directory"] = str(demo)
        metadata["recording_backdrop"] = "#4a4d54"
        metadata["filetree_setup"] = "bundled init.lua and plugins prepared before recording"
        metadata["chromium_backend"] = "chrome"
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
        if not args.skip_native_window and not args.filetree_only and not args.through_filetree and not args.opening_only:
            metadata["native_window"] = (json.loads((output / "native-window/capture.json").read_text())
                if args.reuse_native_window else native_capture.encode(output))
            (output / "capture.json").write_text(json.dumps(metadata, indent=2) + "\n")
        probe, stream = probe_av1(output / "footage.mp4")
        if [stream["width"], stream["height"]] != [2400, 1500]:
            raise RuntimeError("Incorrect recording size")
        if abs(int(stream["nb_read_frames"]) - metadata["frames"]) > 1:
            raise RuntimeError("Capture and encoded frame counts differ")
        probe['format']['filename'] = 'footage.mp4'
        (output / "probe.json").write_text(json.dumps(probe, indent=2) + "\n")
        (output / "godot.log").write_text(log.replace(str(output), '<take>').replace(str(ROOT), '<repo>'))
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
        if diagram_created:
            shutil.rmtree(diagram_directory)


if __name__ == "__main__":
    main()
