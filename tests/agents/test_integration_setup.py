"""Persistent hook setup and plain launches, isolated from real provider homes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import shlex
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest
import fcntl
import pty
import termios

BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", Path(__file__).resolve().parents[2] / "dist/bin/gft"))


def copy_shell(destination):
    """Copies a shell that keeps running as that copy, so the copy's name is the
    process's program. macOS's /bin/sh only re-executes /bin/bash, and the
    system then reports /bin/bash, not the copy."""
    shutil.copy("/bin/bash" if sys.platform == "darwin" else os.path.realpath("/bin/sh"), destination)


class IntegrationSetupTests(unittest.TestCase):
    def test_claude_model_subprocess_does_not_take_over_pi_integration(self):
        """Pi can run Claude Code as its model. That Claude's hooks stay silent:
        Pi owns the pane. A Claude that Pi did not start reports as usual."""
        payload = json.dumps({"hook_event_name": "SessionStart", "session_id": "bridged", "transcript_path": "/nowhere"})
        hook = shlex.join([str(BIN), "internal", "agent-hook-integrate", "session-start", "--provider", "claude"])
        for parent, reported in (("pi", 0), ("launcher", 1)):
            with self.subTest(parent=parent), tempfile.TemporaryDirectory(prefix="alm-bridge-", dir="/tmp") as tmp:
                base = Path(tmp)
                copy_shell(base / parent)
                copy_shell(base / "claude")
                endpoint = base / "api.sock"
                received = []
                with socket.socket(socket.AF_UNIX) as server:
                    server.bind(str(endpoint)); server.listen(1); server.settimeout(2)
                    def reply():
                        try:
                            with server.accept()[0] as peer:
                                request = json.loads(peer.makefile().readline()); received.append(request)
                                peer.sendall((json.dumps({"id": request["id"], "result": {"adjacent": {"incoming": [], "outgoing": []}}}) + "\n").encode())
                        except TimeoutError:
                            pass
                    thread = threading.Thread(target=reply); thread.start()
                    env = dict(self.env(base / "home", "claude"), GRAFFITTY_SOCKET=str(endpoint), GRAFFITTY_TOKEN="test",
                               PI_CODING_AGENT="true")
                    # parent -> claude -> the hook; each shell stays, so both are ancestors.
                    inner = f"{hook}; exit $?"
                    outer = shlex.join([str(base / "claude"), "-c", inner]) + "; exit $?"
                    result = subprocess.run([str(base / parent), "-c", outer], input=payload, env=env,
                                            capture_output=True, text=True, timeout=10)
                    thread.join(5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(received), reported, result.stdout + result.stderr)
                if not reported:
                    self.assertEqual(result.stdout, "")

    def env(self, home, provider):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_", "PI_"))}
        env["PATH"] = str(BIN.parent) + os.pathsep + env.get("PATH", "")
        env["CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR"] = str(home)
        return env

    def setup(self, home, provider, *args, apply=True):
        return subprocess.run([BIN, "integrate", "agent", provider, *args, *(["--apply"] if apply else [])], env=self.env(home, provider), capture_output=True, text=True, timeout=10)

    def read(self, home, provider):
        path = home / ("config.toml" if provider == "codex" else "settings.json")
        return (tomllib.loads if provider == "codex" else json.loads)(path.read_text())

    def test_preview_and_status_never_create_files(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp) / "missing" / "account"
                result = self.setup(home, provider, apply=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("No files changed", result.stdout)
                self.assertIn("internal agent-hook-integrate", result.stdout)
                self.assertIn("--apply", result.stdout)
                self.assertFalse(home.parent.exists())
                status = self.setup(home, provider, "--status", apply=False)
                self.assertNotEqual(status.returncode, 0)
                self.assertIn("0/8" if provider == "claude" else "0/7", status.stdout)
                self.assertFalse(home.parent.exists())

    def test_preview_removal_and_status_preserve_existing_config_and_backup(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                path = home / ("settings.json" if provider == "claude" else "config.toml")
                path.write_text(json.dumps({"unrelated_secret": "DO_NOT_PRINT"}) if provider == "claude" else 'unrelated_secret = "DO_NOT_PRINT"\n')
                before = path.read_bytes()
                preview = self.setup(home, provider, apply=False)
                self.assertEqual(preview.returncode, 0, preview.stderr)
                self.assertNotIn("DO_NOT_PRINT", preview.stdout)
                self.assertIn("… unchanged", preview.stdout)
                self.assertIn("@@", preview.stdout)
                self.assertIn('  \"hooks\": {', preview.stdout)
                self.assertNotIn("\x1b[", preview.stdout)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(list(home.iterdir()), [path])
                self.assertEqual(self.setup(home, provider).returncode, 0)
                snapshot = {p.name: p.read_bytes() for p in home.iterdir()}
                status = self.setup(home, provider, "--status", apply=False)
                self.assertEqual(status.returncode, 0, status.stderr)
                self.assertIn("8/8" if provider == "claude" else "7/7", status.stdout)
                removal = self.setup(home, provider, "--remove", apply=False)
                self.assertEqual(removal.returncode, 0, removal.stderr)
                self.assertIn("No files changed", removal.stdout)
                self.assertNotIn("DO_NOT_PRINT", removal.stdout)
                self.assertEqual({p.name: p.read_bytes() for p in home.iterdir()}, snapshot)
                self.assertEqual(self.setup(home, provider, "--remove").returncode, 0)
                status = self.setup(home, provider, "--status", apply=False)
                self.assertNotEqual(status.returncode, 0)
                self.assertIn("0/8" if provider == "claude" else "0/7", status.stdout)

    def test_status_detects_stale_commands_and_disabled_or_untrusted_hooks(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                self.assertEqual(self.setup(home, provider).returncode, 0)
                path = home / ("settings.json" if provider == "claude" else "config.toml")
                good = path.read_text()
                path.write_text(good.replace("agent-hook-integrate session-start", "agent-hook-integrate invalid-action"))
                status = self.setup(home, provider, "--status", apply=False)
                self.assertNotEqual(status.returncode, 0)
                self.assertIn("outdated command", status.stdout)
                path.write_text(good)
                if provider == "claude":
                    parsed = json.loads(good); parsed["disableAllHooks"] = True
                    path.write_text(json.dumps(parsed))
                    expected = "disabled globally"
                else:
                    path.write_text(good.replace("sha256:", "invalid:"))
                    expected = "untrusted or outdated"
                status = self.setup(home, provider, "--status", apply=False)
                self.assertNotEqual(status.returncode, 0)
                self.assertIn(expected, status.stdout)

    def test_modified_callback_is_repaired_and_retrusts_codex(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                self.assertEqual(self.setup(home, provider).returncode, 0)
                path = home / ("settings.json" if provider == "claude" else "config.toml")
                good = self.read(home, provider)
                path.write_text(path.read_text().replace("agent-hook-integrate session-start", "agent-hook-integrate invalid-action"))
                self.assertNotEqual(self.setup(home, provider, "--status", apply=False).returncode, 0)
                result = self.setup(home, provider)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.read(home, provider), good)
                self.assertEqual(self.setup(home, provider, "--status", apply=False).returncode, 0)

    def test_conflicting_flags_do_not_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "absent"
            result = self.setup(home, "codex", "--status")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(home.exists())

    def test_claude_inbound_delivery_preview_apply_status_and_removal(self):
        for inbound in [None, "hold", "refuse", "accept"]:
            with self.subTest(inbound=inbound), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                path = home / "settings.json"
                original = {"model": "keep"}
                if inbound is not None:
                    original["crossSessionInbound"] = inbound
                path.write_text(json.dumps(original))
                before = path.read_bytes()
                preview = self.setup(home, "claude", apply=False)
                self.assertEqual(preview.returncode, 0, preview.stderr)
                self.assertIn("all sessions using this config", preview.stdout)
                if inbound != "accept":
                    self.assertIn('+  "crossSessionInbound": "accept"', preview.stdout)
                self.assertEqual(path.read_bytes(), before)
                applied = self.setup(home, "claude")
                self.assertEqual(applied.returncode, 0, applied.stderr)
                self.assertEqual(self.read(home, "claude")["crossSessionInbound"], "accept")
                self.assertEqual(self.setup(home, "claude", "--status", apply=False).returncode, 0)
                installed = path.read_bytes()
                self.assertEqual(self.setup(home, "claude").returncode, 0)
                self.assertEqual(path.read_bytes(), installed)
                # Status must catch an existing hook installation whose messaging is blocked.
                config = self.read(home, "claude")
                if inbound is None:
                    config.pop("crossSessionInbound")
                else:
                    config["crossSessionInbound"] = inbound
                path.write_text(json.dumps(config))
                status = self.setup(home, "claude", "--status", apply=False)
                self.assertEqual(status.returncode == 0, inbound == "accept")
                self.assertIn("crossSessionInbound:", status.stdout)
                removed = self.setup(home, "claude", "--remove")
                self.assertEqual(removed.returncode, 0, removed.stderr)
                self.assertIn("preserves crossSessionInbound", removed.stdout)
                self.assertEqual(self.read(home, "claude").get("crossSessionInbound"), inbound)
                self.assertEqual(self.read(home, "claude")["model"], "keep")

    def test_removing_absent_hooks_preserves_empty_user_groups_and_formatting(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp); path = home / "settings.json"
            original = '{ "hooks": {"Stop": [{"matcher": "user", "hooks": []}]}, "model": "keep" }\n'
            path.write_text(original)
            result = self.setup(home, "claude", "--remove")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("No changes needed", result.stdout)
            self.assertEqual(path.read_text(), original)
            self.assertFalse(path.with_name(path.name + ".graffitty-backup").exists())

    def test_preserves_settings_and_hooks_idempotently_and_removes_only_own(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                path = home / ("config.toml" if provider == "codex" else "settings.json")
                original = '# my comments\nmodel = "keep-model"\n[hooks]\nStop = [{hooks=[{type="command",command="echo keep",timeout=7}]}]\n[hooks.state.other]\nenabled = false\n' if provider == "codex" else json.dumps({"model": "keep-model", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo keep", "timeout": 7}]}]}, "permissions": {"allow": ["Read"]}})
                path.write_text(original)
                for _ in range(2):
                    result = self.setup(home, provider)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    parsed = self.read(home, provider)
                    self.assertEqual(parsed["model"], "keep-model")
                    self.assertEqual(len(parsed["hooks"]["Stop"]), 2)
                    self.assertEqual(parsed["hooks"]["Stop"][0]["hooks"][0]["command"], "echo keep")
                installed = path.read_text()
                self.assertEqual(self.setup(home, provider).returncode, 0)
                self.assertEqual(path.read_text(), installed)
                self.assertEqual(path.with_name(path.name + ".graffitty-backup").read_text(), original)
                if provider == "codex":
                    self.assertIn("# my comments", installed)
                    self.assertFalse(parsed["hooks"]["state"]["other"]["enabled"])
                    h = parsed["hooks"]["SessionStart"][0]["hooks"][0]
                    identity = {"event_name": "session_start", "hooks": [{"async": False, **h}]}
                    digest = "sha256:" + hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
                    self.assertEqual(parsed["hooks"]["state"][f"{path.resolve()}:session_start:0:0"]["trusted_hash"], digest)
                self.assertEqual(self.setup(home, provider, "--remove").returncode, 0)
                removed = self.read(home, provider)
                self.assertEqual(removed["model"], "keep-model")
                self.assertEqual(removed["hooks"]["Stop"][0]["hooks"][0]["command"], "echo keep")
                self.assertNotIn("gft internal agent-hook-integrate", path.read_text())
                if provider == "codex":
                    self.assertEqual(removed["hooks"]["state"], {"other": {"enabled": False}})
                self.assertEqual(self.setup(home, provider, "--remove").returncode, 0)

    def test_corrupt_settings_are_not_overwritten(self):
        for provider, name in [("claude", "settings.json"), ("codex", "config.toml")]:
            with tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp); path = home / name
                path.write_text("invalid ! syntax")
                result = self.setup(home, provider)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_text(), "invalid ! syntax")

    def test_symlinked_codex_config_keeps_its_identity_and_other_hook_indices(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); home = base / "home"; home.mkdir()
            target = base / "dotfiles.toml"
            target.write_text('# dotfiles comment\nmodel = "keep"\n')
            (home / "config.toml").symlink_to(target)
            self.assertEqual(self.setup(home, "codex").returncode, 0)
            self.assertTrue((home / "config.toml").is_symlink())
            config = self.read(home, "codex")
            self.assertIn(f"{home.resolve()}/config.toml:stop:0:0", config["hooks"]["state"])
            self.assertNotIn(f"{target.resolve()}:stop:0:0", config["hooks"]["state"])
            # A user's later-added group must keep its index and trust state on removal.
            with target.open("a") as f:
                f.write('\n[[hooks.Stop]]\nhooks = [{type="command",command="echo later"}]\n')
            self.assertEqual(self.setup(home, "codex", "--remove").returncode, 0)
            removed = self.read(home, "codex")
            self.assertEqual(removed["hooks"]["Stop"][0]["hooks"], [])
            self.assertEqual(removed["hooks"]["Stop"][1]["hooks"][0]["command"], "echo later")
            self.assertIn("# dotfiles comment", target.read_text())

    def test_hooks_are_noops_outside_graffitty_and_when_server_has_exited(self):
        for provider in ["claude", "codex"]:
            with tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                self.assertEqual(self.setup(home, provider).returncode, 0)
                command = self.read(home, provider)["hooks"]["SessionStart"][0]["hooks"][0]["command"]
                for extra in [{}, {"GRAFFITTY_SOCKET": str(home / "gone.sock"), "GRAFFITTY_TOKEN": "expired"}]:
                    result = subprocess.run(["/bin/sh", "-c", command], input=json.dumps({"hook_event_name": "SessionStart"}), env=dict(self.env(home, provider), **extra), capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_accounts_can_share_symlinked_codex_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); shared = base / "shared.toml"; shared.write_text('model="keep"\n')
            homes = [base / "work", base / "personal"]
            commands = []
            for home in homes:
                home.mkdir(); (home / "config.toml").symlink_to(shared)
                result = self.setup(home, "codex")
                self.assertEqual(result.returncode, 0, result.stderr)
                commands.append(self.read(home, "codex")["hooks"]["SessionStart"][0]["hooks"][0]["command"])
            self.assertEqual(commands[0], commands[1])
            config = self.read(homes[0], "codex")
            hashes = [config["hooks"]["state"][f"{h.resolve()}/config.toml:session_start:0:0"]["trusted_hash"] for h in homes]
            self.assertEqual(hashes[0], hashes[1])

    def test_plain_provider_owns_hook_through_shell_wrappers_and_custom_home(self):
        for provider in ["claude", "codex"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory(prefix="alm-hooks-", dir="/tmp") as tmp:
                base = Path(tmp); home = base / "account with 'quotes'"
                result = self.setup(home, provider)
                self.assertEqual(result.returncode, 0, result.stderr)
                executable = base / provider
                copy_shell(executable)
                command = self.read(home, provider)["hooks"]["SessionStart"][0]["hooks"][0]["command"]
                endpoint = base / "api.sock"
                received = []
                with socket.socket(socket.AF_UNIX) as server:
                    server.bind(str(endpoint)); server.listen(1); server.settimeout(5)
                    def reply():
                        with server.accept()[0] as peer:
                            req = json.loads(peer.makefile().readline()); received.append(req)
                            peer.sendall((json.dumps({"id": req["id"], "result": {"adjacent": {"incoming": [], "outgoing": []}}}) + "\n").encode())
                    thread = threading.Thread(target=reply); thread.start()
                    env = dict(self.env(home, provider), GRAFFITTY_SOCKET=str(endpoint), GRAFFITTY_TOKEN="test", GRAFFITTY_AGENT_PID="999999")
                    payload = {"hook_event_name": "SessionStart", "session_id": "test-session", "transcript_path": str(home / "test.jsonl")}
                    # The copied shell represents an ordinary native provider process.
                    master, slave = pty.openpty()
                    def own_terminal():
                        os.setsid()
                        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                        os.tcsetpgrp(slave, os.getpgrp())
                    try:
                        # Codex hooks must belong to a foreground TUI, not an
                        # unrelated daemon inheriting a stale workspace token.
                        result = subprocess.run([executable, "-c", '/bin/sh -c "$1"; printf "\\nPARENT=%s\\n" "$$"', provider, command], input=json.dumps(payload), env=env, capture_output=True, text=True, timeout=10, pass_fds=(slave,), preexec_fn=own_terminal)
                    finally:
                        os.close(slave)
                        os.close(master)
                    thread.join(5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(received), 1, result.stdout)
                params = received[0]["params"]
                self.assertEqual(params["pid"], int(result.stdout.split("PARENT=")[-1]))
                self.assertEqual(params["provider_home"], str(home.resolve()))
                self.assertTrue(params["started"])
                self.assertIn("graph adjacent", result.stdout)
