#!/usr/bin/env python3
"""Record the Bistro tour: nine prepared sessions visited from the sidebar.

Everything runs against a private session server and a disposable copy of
the bistro-orders repository; the user's live sessions are never touched.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support"), str(ROOT / "videos/shared")]
from av1 import check_encoder, probe_av1
from e2e_background import prepare_background, clear_background, background_failures
from e2e_bistro import installed_bistro, link_bistro
from e2e_server import PrivateServer
import fixtures

# A demo path free of account names: pane titles and prompts show it on camera.
DEMO = Path("/Users/Shared/gft/demo/bistro-orders")
PORT = 8090


def port_free(port):
    with socket.socket() as probe:
        return probe.connect_ex(("127.0.0.1", port)) != 0


def encode_webm(source: Path, target: Path):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source), "-an", "-c:v", "libvpx-vp9",
                    "-crf", "26", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2",
                    "-pix_fmt", "yuv420p", str(target)], check=True)


REPORTS = Path.home() / "Library/Logs/DiagnosticReports"


def renderer_reports():
    return {path.name for path in REPORTS.glob("Graffitty Helper (Renderer)*.ips")} if REPORTS.is_dir() else set()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New take directory")
    parser.add_argument("--webm", type=Path, default=ROOT / "videos/artifacts/bistro-tour.webm")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    if DEMO.exists():
        raise SystemExit(f"{DEMO} already exists; remove the previous recording's repository first")
    if not port_free(PORT):
        raise SystemExit(f"Port {PORT} is in use; the recorded server needs it")
    if not (ROOT / "dist/filetree/manifest.json").is_file():
        raise SystemExit("Run tools/build_filetree_runtime.py before recording")
    cli = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "dist/bin/gft")).resolve()
    if not cli.is_file():
        raise SystemExit("Build the current CLI with mise run cli:build before recording")
    spec = importlib.util.spec_from_file_location("effects", ROOT / "videos/effects/recording/record.py")
    effects = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(effects)

    reports_before = renderer_reports()
    DEMO.parent.mkdir(parents=True, exist_ok=True)
    fixtures.build_repository(DEMO)
    fixtures.agents(out)
    try:
        shutil.copy2(HERE / "launch.py", out / "launch.py")
        zdot = out / "zdot"
        zdot.mkdir()
        shutil.copy2(HERE / "zshrc", zdot / ".zshrc")
        shutil.copy2(ROOT / "apps/server/shell-integration/integration.sh", zdot / "integration.sh")
        editor = out / "config/bistro-nvim"
        editor.mkdir(parents=True)
        shutil.copy2(HERE / "init.lua", editor / "init.lua")
        (out / "animation-clock").write_text("0")
        shell = out / "shell.sh"
        shell.write_text("#!/bin/sh\ncd " + shlex.quote(str(DEMO)) + "\nexec /usr/bin/env ZDOTDIR="
                         + shlex.quote(str(zdot)) + " /bin/zsh -d -i\n")
        shell.chmod(0o700)
        project = effects.stage_project(out, "2400x1500")
        (project / "llm-e2e").symlink_to(ROOT / "tests/llm-e2e", target_is_directory=True)
        checked = subprocess.run([shutil.which("godot"), "--headless", "--path", str(project), "--check-only",
                                  "--script", "res://videos/bistro-tour/recording/BistroTour.gd"],
                                 capture_output=True, text=True, timeout=300)
        if "SCRIPT ERROR" in checked.stdout + checked.stderr:
            raise SystemExit("Recorder syntax check failed:\n" + checked.stdout + checked.stderr)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_", "SLACK_"))}
        clear_background(env)
        bin_dir = out / "bin"
        bin_dir.mkdir()
        (bin_dir / "gft").symlink_to(cli)
        env.update(XDG_CONFIG_HOME=str(out / "config"), XDG_DATA_HOME=str(out / "data"),
                   XDG_CACHE_HOME=str(out / "cache"), DEMO_RUNTIME=str(out), GRAFFITTY_BIN=str(cli),
                   PATH=os.pathsep.join([str(bin_dir), env["PATH"]]),
                   GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_MOVIE_PAUSED="1",
                   GRAFFITTY_AV1_CRF="15", GRAFFITTY_AV1_PRESET="8")
        # Bistro is an installed world; expose it in the isolated data folder.
        link_bistro(out / "data", installed_bistro())
        command = [shutil.which("godot"), *prepare_background(env, out), "--path", str(project),
                   "--language", "en", "--write-movie", str(out / "footage.mp4"), "--fixed-fps", "60",
                   "--quit-after", "36000", "--script", "res://videos/bistro-tour/recording/BistroTour.gd",
                   "--", "--record", "--tabs=1", "--shell=" + str(shell), "--cwd=" + str(DEMO),
                   "--plugin=bistro", "--world=3d", "--bg=#4a4d54", "--opacity=1",
                   "--no-focus-skip", "--demo-output=" + str(out), "--demo-directory=" + str(DEMO)]
        (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        # Holder sockets live beside the descriptor and must stay under macOS's
        # 104-byte limit; agent transcripts stay out of the take's long path.
        with tempfile.TemporaryDirectory(prefix="gft-tour-", dir="/tmp") as owner:
            env["XDG_STATE_HOME"] = str(Path(owner) / "state")
            try:
                with PrivateServer(env, Path(owner), str(shell)):
                    with (out / "godot.log").open("w") as log:
                        subprocess.run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       check=False, timeout=2400)
            finally:
                shutil.copytree(Path(owner) / "session-owner", out / "session-owner",
                                ignore=shutil.ignore_patterns("*.sock"), dirs_exist_ok=True)
    finally:
        shutil.copytree(DEMO, out / "repository", symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.rmtree(DEMO)
    log = out / "godot.log"
    log.write_text(log.read_text().replace(str(out), "<take>").replace(str(ROOT), "<repo>"))
    if not (out / "capture.json").is_file():
        raise SystemExit("Recording ended before the tour; inspect godot.log and session-owner/server.log")
    # The bundled CEF renderer is known to abort about a minute after launch
    # (see BistroTour.gd); record any such crash, on or off camera.
    crashes = sorted(renderer_reports() - reports_before)
    if (out / "tour.json").is_file():
        tour = json.loads((out / "tour.json").read_text())
        tour["menu_page_renderer"]["macos_crash_reports"] = crashes
        (out / "tour.json").write_text(json.dumps(tour, indent=2) + "\n")
    capture = json.loads((out / "capture.json").read_text())
    failures = capture["failures"] + background_failures(out)
    if failures or "BISTROTOUR_REPLAY_PASS" not in log.read_text():
        raise SystemExit("Tour failed: " + json.dumps(failures, indent=2))
    probe, stream = probe_av1(out / "footage.mp4")
    if [stream["width"], stream["height"]] != [2400, 1500]:
        raise SystemExit("Incorrect recording size")
    if abs(int(stream["nb_read_frames"]) - capture["frames"]) > 1:
        raise SystemExit("Capture and encoded frame counts differ")
    probe["format"]["filename"] = "footage.mp4"
    (out / "probe.json").write_text(json.dumps(probe, indent=2) + "\n")
    encode_webm(out / "footage.mp4", args.webm.resolve())
    print(args.webm.resolve())


if __name__ == "__main__":
    main()
