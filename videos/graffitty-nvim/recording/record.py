#!/usr/bin/env python3
"""Record the graffitty.nvim README demo with private shells and real replay inputs."""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
sys.path.insert(0, str(ROOT / "videos/shared"))
from av1 import check_encoder, probe_av1
from demo_container import build_image
from e2e_background import background_failures, clear_background, prepare_background
from e2e_server import PrivateServer

loader = importlib.machinery.SourceFileLoader("record_effects", str(ROOT / "videos/effects/recording/record.py"))
effects = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(effects)

SCENES = ["ipython", "bash", "neovim", "fyler", "tabs"]
NVIM_APPNAME = "nvim-graffitty-nvim-demo"
REPLAY = "res://videos/graffitty-nvim/recording/GraffittyNvimDemo.gd"
# The README video is watched small; a larger font keeps code readable there.
FONT_SIZE = 18


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def verify_typing_phrases():
    """Fail before fixture setup, not minutes into an expensive recording."""
    plans = json.loads((ROOT / "videos/shared/typing/timings.json").read_text(encoding="utf-8"))["phrases"]
    source = (HERE / "GraffittyNvimDemo.gd").read_text(encoding="utf-8")
    required = set(re.findall(r'\b(?:human_text|send)\("((?:\\.|[^"\\])*)"', source))
    missing = required - plans.keys()
    if missing:
        raise ValueError(f"Missing typing schedules {sorted(missing)}; update phrases.json and run videos/shared/typing/build.py")


def zshrc(fast_syntax_highlighting):
    # The main demo's minimal zsh, plus AUTO_CD so a sent directory path enters
    # it, and comments typed at the prompt, as in the original demo.
    rc = (ROOT / "videos/main-demo/recording/tiling/zshrc").read_text()
    rc = rc.replace("/opt/fast-syntax-highlighting", str(fast_syntax_highlighting))
    return rc + "setopt autocd interactivecomments\n"


def main():
    verify_typing_phrases()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-image", default="localhost/graffitty-effects:4")
    parser.add_argument("--image", default="localhost/graffitty-nvim-demo:1")
    parser.add_argument("--connection", default="podman-machine-default",
                        help="Podman connection with a running VM")
    parser.add_argument("--godot", default=shutil.which("godot"))
    parser.add_argument("--build-image", action="store_true", help="Rebuild the effects and demo images first")
    parser.add_argument("--scene", choices=SCENES, help="Rehearse one scene")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    podman = [shutil.which("podman"), "--connection", args.connection]
    if args.build_image:
        build_image(podman, args.base_image)
        run([*podman, "build", "--build-arg", "BASE=" + args.base_image, "-t", args.image,
             "-f", HERE / "Containerfile", HERE])
    run([*podman, "image", "exists", args.image])
    host_workspace = Path("/Users/Shared/gft")
    demo = host_workspace / "demo"
    if host_workspace.exists() or host_workspace.is_symlink():
        raise RuntimeError("The isolated recording needs an unused " + str(host_workspace))
    name = "graffitty-nvim-" + uuid.uuid4().hex[:12]
    runtime = Path("/tmp") / name
    runtime.symlink_to(output, target_is_directory=True)
    container_created = False
    try:
        shutil.copytree(HERE / "fixture", demo)
        run([*podman, "run", "-d", "--name", name, "--network=none", args.image], stdout=subprocess.DEVNULL)
        container_created = True
        run([*podman, "cp", ROOT / "apps/server/terminfo/xterm-ghostty.terminfo", name + ":/tmp/xterm-ghostty.terminfo"])
        run([*podman, "exec", name, "tic", "-x", "/tmp/xterm-ghostty.terminfo"])
        run([*podman, "exec", name, "useradd", "--create-home", "--home-dir", "/home/demo", "demo"])
        run([*podman, "exec", name, "mkdir", "-p", "/opt/nvim-demo"])
        (output / "container-zshrc").write_text(zshrc("/opt/fast-syntax-highlighting"))
        run([*podman, "cp", output / "container-zshrc", name + ":/opt/nvim-demo/.zshrc"])
        run([*podman, "cp", ROOT / "apps/server/shell-integration/integration.sh", name + ":/opt/nvim-demo/integration.sh"])
        run([*podman, "cp", name + ":/opt/fast-syntax-highlighting", output / "fast-syntax-highlighting"])
        host_shell = runtime / "host-shell"
        host_shell.mkdir()
        shutil.copyfile(ROOT / "apps/server/shell-integration/integration.sh", host_shell / "integration.sh")
        (host_shell / ".zshrc").write_text(zshrc(runtime / "fast-syntax-highlighting")
            + f"export NVIM_APPNAME={NVIM_APPNAME}\n"
            + "vi() { nvim \"$@\"; }\nvimdiff() { nvim -d \"$@\"; }\n")
        nvim_config = runtime / "config" / NVIM_APPNAME
        nvim_config.mkdir(parents=True)
        shutil.copyfile(HERE / "init.lua", nvim_config / "init.lua")
        (runtime / "demo.conf").write_text(f"[terminal]\nfont_size={FONT_SIZE}\n")
        # New panes read next-pane: Neovim needs the host's gft; REPLs and plain
        # shells run as the private demo user in the Podman image.
        podman_config = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
        shell = output / "shell.sh"
        shell.write_text("#!/bin/sh\n"
            + "if [ \"$(cat " + shlex.quote(str(runtime / "next-pane")) + " 2>/dev/null)\" = host ]; then\n"
            + "cd " + shlex.quote(str(demo)) + "\nexec " + shlex.join([
                # The demo folder is home, so prompts read ~/project rather than repeating it.
                "/usr/bin/env", "HOME=" + str(demo), "ZDOTDIR=" + str(host_shell), "/bin/zsh", "-d", "-i"]) + "\nfi\nexec " + shlex.join([
                "/usr/bin/env", "XDG_CONFIG_HOME=" + podman_config, *podman, "exec", "-it",
                "-e", "ZDOTDIR=/opt/nvim-demo", "-w", "/home/demo", name,
                "runuser", "-u", "demo", "--", "/bin/zsh", "-d", "-i"]) + "\n")
        shell.chmod(0o700)
        project = effects.stage_project(output, "2400x1500")
        (project / "llm-e2e").symlink_to(ROOT / "tests/llm-e2e", target_is_directory=True)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL", "NVIM"))}
        clear_background(env)
        env.update(XDG_CONFIG_HOME=str(runtime / "config"), XDG_STATE_HOME=str(runtime / "state"),
                   XDG_DATA_HOME=str(runtime / "data"), XDG_CACHE_HOME=str(runtime / "cache"),
                   GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_MOVIE_PAUSED="1",
                   GRAFFITTY_AV1_CRF="15", GRAFFITTY_AV1_PRESET="8", DEMO_RUNTIME=str(runtime))
        bin_dir = runtime / "bin"
        bin_dir.mkdir()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        checked = run([args.godot, "--headless", "--path", project, "--check-only", "--script", REPLAY],
                      env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        (output / "replay.check.log").write_text(checked.stdout)
        if "SCRIPT ERROR" in checked.stdout or "ERROR:" in checked.stdout:
            raise RuntimeError("Replay syntax check failed\n" + checked.stdout)
        # Install the plugins off camera, in this take's private directories.
        with (output / "nvim-setup.log").open("w") as log:
            run(["nvim", "--headless", "+Lazy! sync", "+qa"], env={**env, "NVIM_APPNAME": NVIM_APPNAME},
                stdout=log, stderr=subprocess.STDOUT, timeout=300)
        lazy = runtime / "data" / NVIM_APPNAME / "lazy"
        for plugin in ["graffitty.nvim", "fyler.nvim", "tokyonight.nvim", "nvim-web-devicons"]:
            if not (lazy / plugin / "lua").is_dir():
                raise RuntimeError("Neovim plugin did not install: " + plugin)
        commit = subprocess.check_output(["git", "-C", str(lazy / "graffitty.nvim"), "rev-parse", "HEAD"], text=True).strip()
        command = [args.godot, *prepare_background(env, output), "--path", str(project),
                   "--language", "en",
                   "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                   "--quit-after", "36000", "--script", REPLAY, "--",
                   "--record", "--tabs=1", "--shell=" + str(shell), "--cwd=" + str(demo),
                   "--bg=#4a4d54", "--opacity=1", "--no-focus-skip",
                   "--config=" + str(runtime / "demo.conf"),
                   "--demo-output=" + str(output), "--demo-directory=" + str(demo)]
        if args.scene:
            command.append("--scene=" + args.scene)
        (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        with PrivateServer(env, output, str(shell)) as owner:
            # Neovim's sends must use the same build as their server.
            (bin_dir / "gft").symlink_to(owner.binary)
            with (output / "godot.log").open("w") as log:
                run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
        if not (output / "capture.json").is_file():
            raise RuntimeError("Recording ended before the replay; inspect godot.log and session-owner/server.log")
        metadata = json.loads((output / "capture.json").read_text())
        metadata.update(graffitty_nvim_commit=commit, container_image=args.image,
                        podman_connection=args.connection, font_size=FONT_SIZE,
                        recording_backdrop="#4a4d54")
        (output / "capture.json").write_text(json.dumps(metadata, indent=2) + "\n")
        errors = metadata["failures"] + background_failures(output)
        if errors:
            raise RuntimeError(str(errors))
        if "GRAFFITTYNVIMDEMO_REPLAY_PASS" not in (output / "godot.log").read_text():
            raise RuntimeError("Replay did not pass; inspect godot.log")
        probe, stream = probe_av1(output / "footage.mp4")
        if [stream["width"], stream["height"]] != [2400, 1500]:
            raise RuntimeError("Incorrect recording size")
        if abs(int(stream["nb_read_frames"]) - metadata["frames"]) > 1:
            raise RuntimeError("Capture and encoded frame counts differ")
        (output / "probe.json").write_text(json.dumps(probe, indent=2) + "\n")
        print(output / "footage.mp4")
    finally:
        if container_created:
            run([*podman, "rm", "-f", name], stdout=subprocess.DEVNULL)
        if demo.exists():
            shutil.copytree(demo, output / "demo")
        if host_workspace.exists():
            shutil.rmtree(host_workspace)
        runtime.unlink()


if __name__ == "__main__":
    main()
