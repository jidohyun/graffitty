"""Record graph chapters using real providers and private Windows homes."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support"), str(ROOT / "tests/agents"), str(ROOT / "videos/shared"),
               str(ROOT / "videos/main-demo/recording/tiling")]
from av1 import check_encoder, probe_av1
from e2e_server import PrivateServer
from record_windows import prepare_project
from test_agent_e2e import seed_auth, restrict_windows_directory, stop_private_codex_helpers


def main(default_chapter="parallel"):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GRAFFITTY_GODOT"))
    parser.add_argument("--through-wiring", action="store_true")
    parser.add_argument("--chapter", choices=("parallel", "systemone", "protocol"), default=default_chapter)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("record_effects", ROOT / "videos/effects/recording/record.py")
    effects = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(effects)
    project = prepare_project(output, effects, args.godot)
    audio = ROOT / "videos/main-demo/composition/demo-audio.json"
    if audio.exists():
        shutil.copyfile(audio, output / audio.name)
    if args.chapter != "parallel":
        subprocess.run([sys.executable, ROOT / "videos/main-demo/recording/systemone/fixtures.py", output], check=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GRAFFITTY_", "CODEX_")) and k != "CLAUDECODE"}
    env.update({f"XDG_{kind}_HOME": str(output / kind.lower()) for kind in ("CONFIG", "STATE", "CACHE", "DATA")})
    env.update(DEMO_RUNTIME=str(output), GRAFFITTY_FFMPEG=check_encoder(),
               GRAFFITTY_MOVIE_PAUSED="1", GRAFFITTY_AV1_CRF="15", GRAFFITTY_AV1_PRESET="8",

               MISE_DATA_DIR=str(Path(env["LOCALAPPDATA"]) / "mise"),
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1",
               CLAUDE_CODE_MAX_OUTPUT_TOKENS="4096", MAX_THINKING_TOKENS="0")
    cli = ROOT / "dist/bin/gft.exe"
    with tempfile.TemporaryDirectory(prefix="gp-", dir=ROOT / ".cache") as folder:
        runtime = Path(folder).resolve()
        restrict_windows_directory(runtime)
        codex, claude, work = [runtime / name for name in ("codex", "claude", "work")]
        for path in (codex, claude, work):
            path.mkdir()
        # Bound provider project discovery to the disposable demo, not this
        # checkout's parent instructions, trust settings or working-tree diff.
        subprocess.run(["git", "init", "--quiet", str(work)], check=True)
        env.update(CODEX_HOME=str(codex), CLAUDE_CONFIG_DIR=str(claude), GRAFFITTY_DEMO_AGENT_HOME=str(runtime))
        try:
            (codex / "config.toml").write_text(
                'model="gpt-6-luna"\nmodel_reasoning_effort="low"\ncheck_for_update_on_startup=false\n'
                'approval_policy="never"\nsandbox_mode="workspace-write"\n'
                '[windows]\nsandbox="mxc"\n'
                f'[projects.{json.dumps(str(work))}]\ntrust_level="trusted"\n', encoding="utf-8")
            if args.chapter != "protocol":
                # Check the actual sandbox before copying account credentials or
                # spending turns on workers that cannot create their deliverables.
                probe = subprocess.run([
                    shutil.which("codex"), "sandbox", "--include-managed-config",
                    "--permission-profile", ":workspace", "--cd", str(work), "--",
                    shutil.which("pwsh.exe"), "-NoProfile", "-Command",
                    "Set-Content -LiteralPath sandbox-probe.txt -Value ok -ErrorAction Stop; "
                    "Get-Content -LiteralPath sandbox-probe.txt -ErrorAction Stop",
                ], cwd=work, env=env, capture_output=True, timeout=60)
                (output / "codex-sandbox-preflight.log").write_bytes(probe.stdout + probe.stderr)
                if probe.returncode != 0 or not (work / "sandbox-probe.txt").is_file():
                    raise RuntimeError("Codex workspace-write sandbox unavailable; see codex-sandbox-preflight.log")
                (work / "sandbox-probe.txt").unlink()
            seed_auth(env, codex, claude, os.environ)
            (claude / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True,
                "projects": {work.as_posix(): {"hasTrustDialogAccepted": True}}}), encoding="utf-8")
            (claude / "settings.json").write_text(json.dumps({"model": "claude-haiku-4-5-20251001",
                "fallbackModel": [], "availableModels": ["claude-haiku-4-5-20251001"],
                "enforceAvailableModels": True}), encoding="utf-8")
            (claude / "mcp-empty.json").write_text('{"mcpServers":{}}', encoding="utf-8")
            instructions = (
                "This is native Windows. Use relative filenames for files in this workspace, "
                "or native absolute paths such as D:/project/file. Never prefix a drive path with /. "
                "This is an isolated, small implementation demo. For 'Implement with spec A', write "
                "spec-A.html: a compact landing page with clear navigation. For spec B write spec-B.html: "
                "responsive navigation, accessible controls and a validated form. For spec C write spec-C.html: "
                "a visual landing page with animated feature sections. Each file must be self-contained and "
                "under 40 lines. Only implement the requested spec. Finish with a concise summary identifying "
                "the spec and its tradeoffs. Do not install dependencies or access the network. "
                "Do not infer the existence or contents of files you have not inspected. "
                "Answer simple questions in two sentences. "
                "Incoming Graffitty graph messages assign tasks to this session: answer the message text; "
                "the attached JSON describes its graph delivery. "
                "When asked to review combined implementations, wait for the graph delivery, read the supplied "
                "session references, compare A, B and C, and give your own recommendation.\n")
            for name in ("AGENTS.md", "CLAUDE.md"):
                (work / name).write_text(instructions, encoding="utf-8")
            if args.chapter == "protocol":
                shutil.copyfile(ROOT / "examples/uppercase-node/node.py", work / "node.py")
                shutil.copyfile(work / "node.py", output / "node.py")
                (work / "pyproject.toml").write_text(
                    '[project]\nname="graph-protocol-demo"\nversion="0.1.0"\nrequires-python=">=3.11"\n'
                    'dependencies=["graffitty-graph-protocol"]\n[tool.uv.sources]\n'
                    'graffitty-graph-protocol={path=' + json.dumps(str(ROOT / "python/libs/graffitty-graph-protocol")) +
                    ',editable=true}\n', encoding="utf-8")
                subprocess.run(["uv", "sync", "--project", work], env=env, check=True,
                               stdout=subprocess.DEVNULL, timeout=180)
            for provider in ("claude", "codex"):
                subprocess.run([cli, "integrate", "agent", provider, "--apply"], cwd=work, env=env,
                               check=True, stdout=subprocess.DEVNULL, timeout=30)
            def ps(value):
                return "'" + str(value).replace("'", "''") + "'"
            shell_script = output / "shell.ps1"
            shell_script.write_text(
                "[Console]::OutputEncoding=[Text.Encoding]::UTF8\n"
                "function prompt { 'PS demo> ' }\n"
                f"function claude {{ & {ps(shutil.which('claude'))} --model claude-haiku-4-5-20251001 "
                f"--effort low --permission-mode dontAsk --tools 'Read,Write,Edit' --allowedTools 'Read,Write,Edit' "
                f"--strict-mcp-config --mcp-config {ps(claude / 'mcp-empty.json')} }}\n"
                f"function codex {{ & {ps(shutil.which('codex'))} -m gpt-6-luna --sandbox workspace-write --ask-for-approval never }}\n"
                f"function bat {{ & {ps(shutil.which('bat'))} --style=plain --paging=never --color=always --theme=TwoDark @args }}\n"
                f"function gft {{ if ($args.Count -ge 2 -and $args[0] -eq 'node' -and $args[1] -eq 'systemone') "
                f"{{ & {ps(cli)} dev systemone-mock --scenario {ps(output / 'decisions.json')} "
                f"--config {ps(output / 'systemone-settings.json')} }} else {{ & {ps(cli)} @args }} }}\n"
                f". {ps(ROOT / 'apps/server/shell-integration/integration.ps1')}\n", encoding="utf-8")
            config = output / "config/graffitty"
            config.mkdir(parents=True)
            shell = [shutil.which("pwsh.exe"), "-NoLogo", "-NoProfile", "-NoExit", "-File", str(shell_script)]
            (config / "server.toml").write_text(
                "[terminal]\nshell=" + json.dumps(shell) + "\nshell_integration=false\n", encoding="utf-8")
            command = [args.godot, "--path", str(project), "--language", "en",
                       "--write-movie", str(output / "footage.mp4"), "--fixed-fps", "60",
                       "--quit-after", "54000", "--script",
                       "res://videos/main-demo/recording/" + {
                           "parallel": "parallel/ParallelDemo.gd",
                           "systemone": "systemone/SystemoneDemo.gd",
                           "protocol": "protocol/ProtocolDemo.gd"}[args.chapter],
                       "--", "--record", "--tabs=1", "--cwd=" + str(work),
                       "--demo-output=" + str(output), "--live-agents", "--no-focus-skip"]
            if args.through_wiring:
                command.append("--through-wiring")
            (output / "command.json").write_text(json.dumps(command, indent=2), encoding="utf-8")
            with PrivateServer(env, output, None):
                with (output / "godot.log").open("w", encoding="utf-8") as log:
                    result = subprocess.run(command, env=env, cwd=ROOT, stdout=log,
                                            stderr=subprocess.STDOUT, timeout=1800)
            metadata = json.loads((output / "capture.json").read_text(encoding="utf-8"))
            if result.returncode or metadata["failures"]:
                raise RuntimeError(args.chapter + " recording failed; inspect " + str(output))
            probe, _ = probe_av1(output / "footage.mp4")
            (output / "probe.json").write_text(json.dumps(probe, indent=2), encoding="utf-8")
            print(output / "footage.mp4")
        finally:
            # Shut down only the private provider processes before removing credentials.
            if (codex / "app-server-control/app-server-control.sock").exists():
                subprocess.run([shutil.which("codex"), "app-server", "daemon", "stop"],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            stop_private_codex_helpers(codex)
            for provider, home, subdir in (("claude", claude, "projects"), ("codex", codex, "sessions")):
                for transcript in (home / subdir).rglob("*.jsonl"):
                    target = output / "transcripts" / provider / transcript.relative_to(home / subdir)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(transcript, target)
            for name in ("spec-A.html", "spec-B.html", "spec-C.html"):
                if (work / name).exists():
                    shutil.copyfile(work / name, output / name)
