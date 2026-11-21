"""Native PowerShell fixtures for the same main-demo replay on Windows."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
from av1 import check_encoder, probe_av1
from e2e_server import PrivateServer


def prepare_markdown_plugins(output):
    # Pin the external APIs used by this recording's MarkdownPreview chapter.
    # These are third-party dependencies, not Graffitty command aliases.
    revisions = {
        "markdown-preview.nvim": "faf50b5e233df953a1fd6946d0a8d758bf2e38a1",
        "live-server.nvim": "f98bae79fd30274524412f7514549d84391d6bb2",
    }
    for name, revision in revisions.items():
        cached = ROOT / ".cache/main-demo/plugins" / name / revision
        if not cached.exists():
            cached.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "clone", "--no-checkout", "--filter=blob:none",
                            f"https://github.com/selimacerbas/{name}.git", str(cached)], check=True)
            subprocess.run(["git", "-C", str(cached), "checkout", "--detach", revision], check=True)
        actual = subprocess.check_output(["git", "-C", str(cached), "rev-parse", "HEAD"], text=True).strip()
        if actual != revision:
            raise RuntimeError(f"Recording plugin checkout differs from its pinned revision: {cached}")
        shutil.copytree(cached, output / "plugins" / name, ignore=shutil.ignore_patterns(".git"))
    (output / "plugin-revisions.json").write_text(json.dumps(revisions, indent=2), encoding="utf-8")


def resource_signature(godot):
    digest = hashlib.sha256((ROOT / "frontends/godot/project/project.godot").read_bytes())
    executable = Path(godot)
    digest.update(str((executable.resolve(), executable.stat().st_mtime_ns)).encode())
    targets = subprocess.check_output(["git", "ls-files", "-z", "*.dvc"], cwd=ROOT).decode().split("\0")
    for name in sorted(filter(None, targets)):
        digest.update(name.encode())
        digest.update((ROOT / name).read_bytes())
    return digest.hexdigest()


def prepare_project(output, effects, godot, reimport=False):
    project = effects.stage_project(output, "2400x1500")
    (project / "llm-e2e").symlink_to(ROOT / "tests/llm-e2e", target_is_directory=True)
    # The capture uses desktop textures. Do not spend a Windows recording
    # preflight compressing Castle HDR textures for mobile ASTC targets.
    project_config = project / "project.godot"
    project_config.write_text(project_config.read_text(encoding="utf-8").replace(
        "textures/vram_compression/import_etc2_astc=true",
        "textures/vram_compression/import_etc2_astc=false"), encoding="utf-8")
    editor_cache = ROOT / ".cache/main-demo/godot-editor"
    stamp = editor_cache / "import.json"
    signature = resource_signature(godot)
    if not reimport and stamp.is_file() and json.loads(stamp.read_text())["signature"] == signature:
        for name in ("extension_list.cfg", "global_script_class_cache.cfg", "uid_cache.bin"):
            shutil.copyfile(editor_cache / name, project / ".godot" / name)
        (output / "import.log").write_text("Reused validated recording imports: " + signature + "\n", encoding="utf-8")
        return project
    private_editor = project / ".godot/editor"
    private_editor.mkdir(exist_ok=True)
    cache_source = editor_cache if editor_cache.exists() else ROOT / "frontends/godot/project/.godot/editor"
    for cached in cache_source.glob("filesystem_cache*"):
        shutil.copyfile(cached, private_editor / cached.name)
    with (output / "import.log").open("w", encoding="utf-8") as log:
        subprocess.run([godot, "--headless", "--path", str(project), "--editor", "--import"],
                       check=True, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
    editor_cache.mkdir(parents=True, exist_ok=True)
    for cached in private_editor.glob("filesystem_cache*"):
        shutil.copyfile(cached, editor_cache / cached.name)
    for name in ("extension_list.cfg", "global_script_class_cache.cfg", "uid_cache.bin"):
        shutil.copyfile(project / ".godot" / name, editor_cache / name)
    stamp.write_text(json.dumps({"signature": signature}), encoding="utf-8")
    return project


def record(args, effects):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # The cwd chapter visits the demo's parent. Keep that visible workspace
    # separate from recording logs and give it its own Git boundary.
    workspace = output / "workspace"
    workspace.mkdir()
    subprocess.run(["git", "init", "--quiet", str(workspace)], check=True)
    demo = workspace / "demo"
    # Reuse real history without making a commit in either checkout.
    subprocess.run(["git", "clone", "--shared", "--no-checkout", str(ROOT), str(demo)], check=True,
                   stdout=subprocess.DEVNULL)
    (demo / "src").mkdir()
    (demo / "docs").mkdir()
    (demo / "README.md").write_text("# Workspace demo\n\nWatch Python source files.\n", encoding="utf-8")
    (demo / "docs/notes.txt").write_text("Workspace plan\n\nKeep related work together.\nNotes, images, and a terminal.\n", encoding="utf-8")
    shutil.copyfile(HERE / "main.py", demo / "src/main.py")
    for name in ("layout.png", "layout.pdf", "video.webm"):
        shutil.copyfile(ROOT / "videos/main-demo/assets/fixtures" / name, demo / "docs" / name)
    for name in ("guide.md", "http-request.html"):
        shutil.copyfile(HERE / name, output / ("http-request-source.html" if name.endswith(".html") else name))
    for name in ("demo-audio.json", "demo-narration.json"):
        source = ROOT / "videos/main-demo/composition" / name
        if source.exists():
            shutil.copyfile(source, output / name)
    project = prepare_project(output, effects, args.godot, args.reimport_resources)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GRAFFITTY_", "CODEX_THREAD", "CODEX_INTERNAL"))}
    env.update({f"XDG_{kind}_HOME": str(output / kind.lower()) for kind in ("CONFIG", "STATE", "CACHE", "DATA")})
    env.update(DEMO_RUNTIME=str(output), GRAFFITTY_FFMPEG=check_encoder(),
               GRAFFITTY_MOVIE_PAUSED="1", GRAFFITTY_AV1_CRF="15", GRAFFITTY_AV1_PRESET="8")
    env.setdefault("MISE_DATA_DIR", str(Path(env["LOCALAPPDATA"]) / "mise"))
    startup = output / "shell.ps1"
    integration = ROOT / "apps/server/shell-integration/integration.ps1"
    startup.write_text(
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8\n"
        "$env:GIT_PAGER=''\n"
        "function prompt { 'PS ' + (Get-Location).Path + '> ' }\n"
        "function claude { & $env:GRAFFITTY_BIN dev claude-mock --config \"$env:DEMO_RUNTIME/claude.json\" }\n"
        "function codex { & $env:GRAFFITTY_BIN dev codex-mock --config \"$env:DEMO_RUNTIME/codex.json\" }\n"
        f". '{str(integration).replace(chr(39), chr(39)*2)}'\n"
        '[Console]::Write(("{0}[2J{0}[H{0}[8mTILING_READY{0}[0m`n" -f [char]27))\n', encoding="utf-8")
    if not args.opening_only:
        nvim = shutil.which("nvim")
        if nvim is None:
            raise RuntimeError("Neovim is required for the filetree and Chromium chapters")
        with startup.open("a", encoding="utf-8") as script:
            script.write(
                "function nvim { $previousApp=$env:NVIM_APPNAME; try { "
                "$env:NVIM_APPNAME='nvim-graffitty-demo'; "
                f"& '{nvim.replace(chr(39), chr(39)*2)}' @args "
                "} finally { $env:NVIM_APPNAME=$previousApp } }\n")
        markdown = output / "config/nvim-graffitty-demo"
        markdown.mkdir(parents=True)
        shutil.copyfile(HERE / "markdown-init.lua", markdown / "init.lua")
        prepare_markdown_plugins(output)
    config = output / "config/graffitty"
    config.mkdir(parents=True)
    shell_name = getattr(args, "windows_shell", "pwsh.exe")
    shell = [shutil.which(shell_name), "-NoLogo", "-NoProfile", "-NoExit", "-File", str(startup)]
    if shell[0] is None:
        raise RuntimeError(f"{shell_name} is required for this Windows demo recording")
    # The fixture sources the production hook after defining its private prompt.
    (config / "server.toml").write_text(
        "[terminal]\nshell = " + json.dumps(shell) + "\nshell_integration = false\n", encoding="utf-8")
    if args.castle:
        shutil.copyfile(HERE / "castle-client.toml", config / "client.toml")
    # The server runs the bundled, sandboxed filetree: no plugin download to prepare.
    if not args.opening_only and not (ROOT / "dist/filetree/manifest.json").is_file():
        raise SystemExit("Run tools/build_filetree_runtime.py before recording")
    class QuietHandler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass
    web = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(HERE)))
    thread = threading.Thread(target=web.serve_forever, daemon=True)
    thread.start()
    try:
        diagram = output / "diagram"
        diagram.mkdir()
        subprocess.run([sys.executable, str(HERE / "scenarios.py"), str(output),
                        f"http://127.0.0.1:{web.server_port}", str(diagram)], check=True, env=env)
        command = [args.godot, "--path", str(project), "--language", "en",
                   "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                   "--quit-after", "36000", "--script", "res://videos/main-demo/recording/tiling/RecordTilingDemo.gd",
                   "--", "--record", "--tabs=1", "--cwd=" + str(demo),
                   "--bg=#4a4d54", "--opacity=1", "--no-focus-skip", "--skip-native-window",
                   "--demo-output=" + str(output), "--demo-directory=" + str(demo)]
        if args.castle:
            command += ["--plugin=edinburgh-castle", "--world=3d"]
        for flag in ("filetree_only", "capture_from_filetree", "opening_only", "filetree_transition_only", "through_filetree", "chromium_only", "markdown_transition_only"):
            if getattr(args, flag):
                command.append("--" + flag.replace("_", "-"))
        (output / "command.json").write_text(json.dumps(command, indent=2), encoding="utf-8")
        with PrivateServer(env, output, None):
            with (output / "godot.log").open("w", encoding="utf-8") as log:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=7200)
        capture = output / "capture.json"
        if not capture.exists():
            raise RuntimeError("Recording did not complete; inspect " + str(output / "godot.log"))
        metadata = json.loads(capture.read_text(encoding="utf-8"))
        metadata.update(shell_backend="powershell", shell_executable=shell[0], working_directory=str(demo),
                        native_window="macOS-only capture omitted")
        capture.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        if result.returncode or metadata["failures"] or "RECORDTILINGDEMO_REPLAY_PASS" not in (output / "godot.log").read_text(encoding="utf-8"):
            raise RuntimeError("Windows chapter failed; inspect " + str(output))
        probe, stream = probe_av1(output / "footage.mp4")
        if [stream["width"], stream["height"]] != [2400, 1500] or abs(int(stream["nb_read_frames"]) - metadata["frames"]) > 1:
            raise RuntimeError("Recording dimensions or frame count do not match the replay")
        (output / "probe.json").write_text(json.dumps(probe, indent=2), encoding="utf-8")
        print(output / "footage.mp4")
    finally:
        web.shutdown()
        web.server_close()
        thread.join()
