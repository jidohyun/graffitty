"""Native checkpoint integration without a GUI or a real provider process."""

import json
import shlex
import shutil
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "dist/bin/gft"))
THREAD = "11111111-1111-4111-8111-111111111111"
SESSION = "22222222-2222-4222-8222-222222222222"


def quoted(text):
    """How restore scripts quote every value."""
    return "'" + text.replace("'", "'\\''") + "'"


class Checkpoints(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alm-checkpoints-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.layout = self.root / "layout.json"
        self.document = {
            "version": 1,
            "windows": [
                {
                    "active": 1,
                    "position": [100, 200],
                    "size": [900, 700],
                    "tabs": [
                        {
                            "id": 1,
                            "focused": "%1",
                            "tree": {"pane": "%1"},
                        }
                    ],
                    "panes": [{"id": 1, "pid": 100, "cwd": "/tmp"}],
                    "chromiums": [],
                }
            ],
        }
        self.layout.write_text(json.dumps(self.document))
        self.processes = self.root / "processes"
        self.processes.write_text(
            "100 1 100 200 ttys001 S Mon Sep 21 10:00:00 2026 /bin/zsh\n"
        )
        self.script("lsof", "exit 1")
        self.script("claude", "exit 1")
        self.env = {
            k: v for k, v in os.environ.items()
            if not k.startswith("GRAFFITTY_") and k not in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "CODEX_SQLITE_HOME")
        }
        self.env.update(
            HOME=str(self.root),
            PATH=f"{self.bin}:/usr/bin:/bin",
            GRAFFITTY_CHECKPOINT_DIR=str(self.state),
        )

    def script(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o700)

    def agent(self, name, **env):
        """A live stand-in that the captured process list reports as the pane's foreground `name`.
        Discovery reads the environment it really started with."""
        sleeper = self.root / "sleep"
        if not sleeper.exists():
            # A copy, because macOS withholds a platform binary's environment.
            shutil.copy("/bin/sleep", sleeper)
        own = {k: v for k, v in self.env.items() if k not in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "CODEX_SQLITE_HOME")}
        process = subprocess.Popen([str(sleeper), "60"], env={**own, **env})
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        self.processes.write_text(
            f"100 1 100 {process.pid} ttys001 S Mon Sep 21 10:00:00 2026 /bin/zsh\n"
            f"{process.pid} 100 {process.pid} {process.pid} ttys001 S Mon Sep 21 10:01:00 2026 /opt/bin/{name}\n"
        )
        return process.pid

    def resumed(self):
        """The script a restore from this history runs in the agent's pane."""
        prepared = self.run_cli("restore", "--prepare-only", "--checkpoint", "0")
        pane = json.loads(Path(prepared["prepared"]).read_text())["windows"][0]["panes"][0]
        return Path(pane["restore_shell"]).read_text()

    def run_cli(self, *args, success=True):
        result = subprocess.run(
            [str(BIN), "checkpoint", *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return json.loads(result.stdout) if success else result.stderr

    def save(self, *args):
        return Path(self.run_cli("save", "--input", str(self.layout), "--processes", str(self.processes), *args)["path"])

    def test_atomic_private_history_and_independent_tags(self):
        self.env["GRAFFITTY_CHECKPOINT_HISTORY"] = "2"
        first = self.save()
        self.save()
        newest = self.save()
        other = self.save("--tag", "../Main")
        self.assertFalse(first.exists())
        self.assertTrue(other.exists())
        self.assertEqual(len(self.run_cli("list")), 2)
        self.assertEqual(self.run_cli("list")[0]["path"], str(newest))
        self.assertEqual(newest.stat().st_mode & 0o777, 0o600)
        self.assertEqual(newest.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse(list(self.state.rglob("*.tmp")))

    def test_invalid_capture_does_not_prune_good_history(self):
        good = self.save()
        self.document["windows"] = []
        self.layout.write_text(json.dumps(self.document))
        self.run_cli("save", "--input", str(self.layout), "--processes", str(self.processes), success=False)
        self.assertTrue(good.exists())
        self.assertEqual(len(self.run_cli("list")), 1)

    def test_codex_resolves_root_session_from_exact_open_rollout(self):
        provider = self.root / "account"
        rollout = provider / "sessions" / f"rollout-today-{THREAD}.jsonl"
        rollout.parent.mkdir(parents=True)
        rollout.write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {"id": THREAD, "session_id": SESSION},
                }
            )
            + "\n"
        )
        self.agent("codex")
        self.script(
            "lsof", f'case "$*" in *"-d cwd"*) echo n/tmp;; *) echo n{rollout};; esac'
        )
        saved = json.loads(self.save().read_text())
        agent = saved["windows"][0]["panes"][0]["agent"]
        self.assertEqual(agent["session_id"], SESSION)
        # The rollout proves the home even when the process names none.
        self.assertEqual(agent["env"], {"CODEX_HOME": str(provider)})
        script = self.resumed()
        self.assertIn(f"export CODEX_HOME={quoted(str(provider))}\nunset CODEX_SQLITE_HOME\n", script)
        # An account alias's own spelling of that home is kept, with the rest of its locations.
        link = self.root / "account link"
        link.symlink_to(provider)
        sqlite = self.root / "sqlite"
        self.agent("codex", CODEX_HOME=str(link), CODEX_SQLITE_HOME=str(sqlite))
        agent = json.loads(self.save().read_text())["windows"][0]["panes"][0]["agent"]
        self.assertEqual(agent["env"], {"CODEX_HOME": str(link), "CODEX_SQLITE_HOME": str(sqlite)})
        self.assertIn(f"export CODEX_HOME={quoted(str(link))}\nexport CODEX_SQLITE_HOME={quoted(str(sqlite))}\n",
                      self.resumed())
        rollout.write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {"id": SESSION, "session_id": THREAD},
                }
            )
            + "\n"
        )
        unresolved = json.loads(self.save().read_text())
        self.assertIsNone(unresolved["windows"][0]["panes"][0]["agent"]["session_id"])

    def test_claude_manifest_requires_matching_process_start(self):
        account = self.root / "account"
        pid = self.agent("claude", CLAUDE_CONFIG_DIR=str(account))
        record = dict(
            pid=pid,
            kind="interactive",
            entrypoint="cli",
            procStart="Mon Sep 21 10:01:00 2026",
            sessionId=SESSION,
        )
        # Only the agent's own configuration holds its manifest.
        default = self.root / f".claude/sessions/{pid}.json"
        default.parent.mkdir(parents=True)
        default.write_text(json.dumps({**record, "sessionId": THREAD}))
        manifest = account / f"sessions/{pid}.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(record))
        agent = json.loads(self.save().read_text())["windows"][0]["panes"][0]["agent"]
        self.assertEqual((agent["session_id"], agent["env"]), (SESSION, {"CLAUDE_CONFIG_DIR": str(account)}))
        record["procStart"] = "Mon Sep 21 10:02:00 2026"
        manifest.write_text(json.dumps(record))
        self.assertIsNone(
            json.loads(self.save().read_text())["windows"][0]["panes"][0]["agent"][
                "session_id"
            ]
        )

    def test_claude_is_found_and_resumed_in_its_own_configuration(self):
        # The helper's own configuration is another account's.
        self.env["CLAUDE_CONFIG_DIR"] = str(self.root / "other")
        account = self.root / "account"
        pid = self.agent("claude", CLAUDE_CONFIG_DIR=str(account))
        # `claude agents` lists only the sessions of the configuration it runs in.
        self.script("claude", f'[ "$*" = "agents --json" ] || exit 1\ncase "$CLAUDE_CONFIG_DIR" in\n'
                    f"{shlex.quote(str(account))}) echo '[{{\"kind\":\"interactive\",\"pid\":{pid},\"sessionId\":\"{SESSION}\"}}]';;\n"
                    "*) echo '[]';;\nesac")
        agent = json.loads(self.save().read_text())["windows"][0]["panes"][0]["agent"]
        self.assertEqual((agent["session_id"], agent["env"]), (SESSION, {"CLAUDE_CONFIG_DIR": str(account)}))
        script = self.resumed()
        self.assertIn(f"export CLAUDE_CONFIG_DIR={quoted(str(account))}\nexec '/opt/bin/claude' '--resume' '{SESSION}'\n", script)
        # A default-account agent resumes in the default configuration, even
        # from an environment that names another.
        pid = self.agent("claude")
        manifest = self.root / f".claude/sessions/{pid}.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(dict(pid=pid, kind="interactive", entrypoint="cli",
                                            procStart="Mon Sep 21 10:01:00 2026", sessionId=THREAD)))
        agent = json.loads(self.save().read_text())["windows"][0]["panes"][0]["agent"]
        self.assertEqual((agent["session_id"], agent["env"]), (THREAD, {}))
        self.assertIn(f"unset CLAUDE_CONFIG_DIR\nexec '/opt/bin/claude' '--resume' '{THREAD}'\n", self.resumed())

    def test_declared_node_relaunches_only_from_your_own_history(self):
        # Pi, OpenCode, built-in and SDK nodes declare how a checkpoint relaunches them.
        with self.processes.open("a") as f:
            f.write("200 100 200 200 ttys001 S Mon Sep 21 10:01:00 2026 /opt/bin/opencode\n")
        pane = self.document["windows"][0]["panes"][0]
        config = str(self.root / "opencode config")
        pane["node"] = {"command": ["/opt/bin/opencode", "--session", "ses_example123"], "cwd": str(self.root),
                        "env": {"OPENCODE_CONFIG_DIR": config, "XDG_DATA_HOME": None}, "state": {"draft": "it's"}, "pid": 200}
        self.layout.write_text(json.dumps(self.document))
        checkpoint = self.save()
        saved = json.loads(checkpoint.read_text())["windows"][0]["panes"][0]
        self.assertEqual(saved["node"], pane["node"])
        self.assertNotIn("agent", saved, "The node's own declaration replaces process discovery")

        def relaunch(path):
            result = subprocess.run([str(BIN), "checkpoint", "restore", "--prepare-only", "--checkpoint", str(path)],
                                    env=self.env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(Path(json.loads(result.stdout)["prepared"]).read_text())["windows"][0]["panes"][0], result.stderr

        restored, _ = relaunch(checkpoint)
        script = Path(restored["restore_shell"]).read_text()
        command = next(shlex.split(line)[1:] for line in script.splitlines() if line.startswith("exec '/opt"))
        self.assertEqual(command, ["/opt/bin/opencode", "--session", "ses_example123"])
        self.assertIn(f"export OPENCODE_CONFIG_DIR={shlex.quote(config)}", script)
        # Null removes a location the node did not have from the restoring shell.
        self.assertIn("\nunset XDG_DATA_HOME\n", script)
        state = Path(next(shlex.split(line.split("=", 1)[1])[0] for line in script.splitlines() if "GRAFFITTY_NODE_STATE=" in line))
        self.assertEqual(json.loads(state.read_text()), {"draft": "it's"})
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        # A built-in node's bare gft is the restoring CLI.
        pane["node"]["command"] = ["gft", "node", "payload-inspector"]
        self.layout.write_text(json.dumps(self.document))
        restored, _ = relaunch(self.save())
        script = Path(restored["restore_shell"]).read_text()
        command = next(shlex.split(line)[1:] for line in script.splitlines() if line.startswith("exec ") and "payload-inspector" in line)
        self.assertEqual((Path(command[0]).resolve(), command[1:]), (BIN.resolve(), ["node", "payload-inspector"]))
        # A checkpoint from elsewhere is data: its node pane comes back as a shell.
        outside = self.root / "shared checkpoint.json"
        outside.write_text(checkpoint.read_text())
        untrusted, warning = relaunch(outside)
        self.assertNotIn("restore_shell", untrusted)
        self.assertNotIn("node", untrusted)
        self.assertIn("not relaunching '/opt/bin/opencode' '--session' 'ses_example123'", warning)
        # A node that exited before the save cannot relaunch.
        pane["node"]["pid"] = 999
        self.layout.write_text(json.dumps(self.document))
        self.assertNotIn("node", json.loads(self.save().read_text())["windows"][0]["panes"][0])

    def test_agent_conversations_resume_only_from_your_own_history(self):
        self.document["windows"][0]["panes"][0]["agent"] = {"kind": "codex", "session_id": SESSION, "executable": str(self.bin / "codex"),
                                                             "env": {"CODEX_HOME": str(self.root / "account")}}
        history = self.state / "manual".encode().hex()
        history.mkdir(parents=True, mode=0o700)
        (history / "checkpoint-00000000000000000001-agent.json").write_text(json.dumps(self.document))
        prepared = self.run_cli("restore", "--prepare-only", "--checkpoint", "0")
        restored = json.loads(Path(prepared["prepared"]).read_text())["windows"][0]["panes"][0]
        script = Path(restored["restore_shell"]).read_text()
        command = next(shlex.split(line)[1:] for line in script.splitlines() if line.startswith("exec ") and not line.endswith(" -l"))
        self.assertEqual(command, [str(self.bin / "codex"), "resume", SESSION])
        self.assertIn(f"export CODEX_HOME={quoted(str(self.root / 'account'))}\nunset CODEX_SQLITE_HOME\n", script)
        # A resume runs the saved executable: a checkpoint from elsewhere is only data.
        outside = self.root / "shared checkpoint.json"
        outside.write_text(json.dumps(self.document))
        result = subprocess.run([str(BIN), "checkpoint", "restore", "--prepare-only", "--checkpoint", str(outside)],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        untrusted = json.loads(Path(json.loads(result.stdout)["prepared"]).read_text())["windows"][0]["panes"][0]
        self.assertNotIn("restore_shell", untrusted)
        self.assertNotIn("agent", untrusted)
        self.assertEqual(result.stderr.strip(), f"pane 1: not resuming codex conversation {SESSION} from a checkpoint outside your checkpoint history")

    def test_ambiguous_foreground_agents_are_not_resumed(self):
        with self.processes.open("a") as f:
            for pid in [200, 201]:
                f.write(
                    f"{pid} 100 200 200 ttys001 S Mon Sep 21 10:01:00 2026 /opt/bin/codex\n"
                )
        self.assertNotIn(
            "agent", json.loads(self.save().read_text())["windows"][0]["panes"][0]
        )

    def test_restore_rejects_invalid_geometry_before_launch(self):
        self.document["windows"][0]["size"] = "bad"
        self.layout.write_text(json.dumps(self.document))
        self.assertIn(
            "geometry",
            self.run_cli("restore", "--checkpoint", str(self.layout), success=False),
        )

    def test_filetree_references_are_validated_and_missing_root_uses_parent(self):
        tree = {"id": 2, "pid": 200, "cwd": "/tmp", "filetree": {"owner": 1, "root": str(self.root / "missing")}}
        window = self.document["windows"][0]
        window["panes"].append(tree)
        window["tabs"][0]["tree"] = {"windows": [{"pane": "%1"}, {"pane": "%2"}]}
        self.layout.write_text(json.dumps(self.document))
        prepared = self.run_cli("restore", "--prepare-only", "--checkpoint", str(self.layout))
        saved = json.loads(Path(prepared["prepared"]).read_text())
        self.assertEqual(saved["windows"][0]["panes"][1]["filetree"], {"owner": 1, "root": str(self.root)})
        self.assertNotIn("restore_shell", saved["windows"][0]["panes"][1])
        for invalid in ({"owner": 999, "root": "/tmp"}, {"owner": 2, "root": "/tmp"}, {"owner": 1, "root": "relative"}):
            tree["filetree"] = invalid
            self.layout.write_text(json.dumps(self.document))
            self.assertIn("filetree", self.run_cli("restore", "--prepare-only", "--checkpoint", str(self.layout), success=False))


if __name__ == "__main__":
    unittest.main()
