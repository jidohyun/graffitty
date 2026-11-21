"""Exercise installed hooks through native Windows shells, without model calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


@unittest.skipUnless(os.name == "nt", "Native Windows hook execution")
class WindowsHooks(unittest.TestCase):
    def test_cmd_hooks(self):
        self.exercise_hooks(["cmd.exe", "/d", "/s", "/c"])

    def test_windows_powershell_51_hooks(self):
        self.exercise_hooks(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command"])

    def test_powershell_7_hooks(self):
        self.exercise_hooks(["pwsh.exe", "-NoProfile", "-NonInteractive", "-Command"])

    def exercise_hooks(self, shell):
        binary = Path(os.environ.get("GRAFFITTY_TEST_CLI", Path(__file__).resolve().parents[3] / "dist/bin/gft.exe"))
        with tempfile.TemporaryDirectory(prefix="graffitty hook's ") as temporary:
            root = Path(temporary)
            cli = root / "gft.exe"
            shutil.copyfile(binary, cli)
            for provider in ("codex", "claude"):
                with self.subTest(provider=provider):
                    home = root / provider
                    home.mkdir()
                    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
                    env["PATH"] = str(root) + os.pathsep + env.get("PATH", "")
                    env["CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR"] = str(home)
                    path = home / ("config.toml" if provider == "codex" else "settings.json")
                    parse = tomllib.loads if provider == "codex" else json.loads
                    modified = "gft internal agent-hook-integrate invalid-action --provider " + provider
                    if provider == "codex":
                        path.write_text('[[hooks.SessionStart]]\nhooks = [{type="command",command="echo unrelated"}]\n'
                                        '[[hooks.SessionStart]]\nhooks = [{type="command",command=' + json.dumps(modified) + '}]\n', encoding="utf-8")
                    else:
                        path.write_text(json.dumps({"hooks": {"SessionStart": [
                            {"hooks": [{"type": "command", "command": command}]}
                            for command in ("echo unrelated", modified)]}}), encoding="utf-8")

                    def integrate(*args):
                        result = subprocess.run([cli, "integrate", "agent", provider, *args], env=env, capture_output=True, text=True, timeout=15, encoding="utf-8")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        return result

                    integrate("--apply")
                    installed = path.read_bytes()
                    integrate("--apply")
                    self.assertEqual(path.read_bytes(), installed)
                    integrate("--status")
                    groups = parse(path.read_text(encoding="utf-8"))["hooks"]["SessionStart"]
                    command = groups[1]["hooks"][0]["command"]
                    self.assertEqual(groups[0]["hooks"][0]["command"], "echo unrelated")
                    self.assertEqual(command, f"gft internal agent-hook-integrate session-start --provider {provider}")
                    hooks = parse(path.read_text(encoding="utf-8"))["hooks"]
                    actions = {
                        "SessionStart": "session-start", "UserPromptSubmit": "prompt-submit",
                        "Stop": "turn-end", "SessionEnd": "session-end", "PreToolUse": "tool-start",
                        "PermissionRequest": "permission-request", "PostToolUse": "tool-end",
                    }
                    for event, action in actions.items():
                        callback = f"gft internal agent-hook-integrate {action} --provider {provider}"
                        registered = [hook["command"] for group in hooks[event] for hook in group["hooks"]]
                        self.assertEqual(registered.count(callback), 1, (event, registered))
                        result = subprocess.run([*shell, callback], env=env, input="", capture_output=True, text=True, timeout=15, encoding="utf-8")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), "")
                    integrate("--remove", "--apply")
                    config = parse(path.read_text(encoding="utf-8"))
                    remaining = [hook["command"] for group in config["hooks"]["SessionStart"] for hook in group["hooks"]]
                    self.assertEqual(remaining, ["echo unrelated"])


if __name__ == "__main__":
    unittest.main()
