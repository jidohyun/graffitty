"""Development restart choices fail closed and target only the selected owner."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tools",)]
import dev_server


class DevServerTests(unittest.TestCase):
    def test_descriptor_override_precedence(self):
        env = {"XDG_STATE_HOME": "/tmp/state", "GRAFFITTY_SERVER_DESCRIPTOR": "/tmp/custom.json"}
        self.assertEqual(dev_server.descriptor_path(env, []), Path("/tmp/custom.json"))
        self.assertEqual(dev_server.descriptor_path(env, ["--session-connection=/tmp/explicit.json"]), Path("/tmp/explicit.json"))

    def test_no_server_does_not_prompt(self):
        with tempfile.TemporaryDirectory() as name, patch("builtins.input") as prompt:
            dev_server.restart_if_requested("missing-binary", Path(name) / "server.json", {})
        prompt.assert_not_called()

    def invoke(self, answers, *, interactive=True, owners=None, fail=None, after=None):
        self.commands = []
        def run(binary, env, *args):
            self.commands.append(args)
            self.assertEqual(env["GRAFFITTY_SERVER_DESCRIPTOR"], "/tmp/selected.json")
            self.assertNotIn("GRAFFITTY_SOCKET", env)
            self.assertNotIn("GRAFFITTY_TOKEN", env)
            if fail in (args[0], " ".join(args[:2])):
                raise RuntimeError("command failed")
            if args[:2] == ("session", "list"):
                count = self.commands.count(args)
                ids = ["$1"] if count == 1 else (after if after is not None else ["$1", "$9"])
                if count == 3:
                    ids = ["$9", "$2"]  # Concurrent new sessions must survive.
                return json.dumps([{"id": i} for i in ids])
            if args[:2] == ("session", "new"):
                return "$2"
            return "done"
        with (patch.object(dev_server, "running_server", side_effect=owners, return_value={"pid": 42}),
              patch.object(dev_server.sys.stdin, "isatty", return_value=interactive),
              patch("builtins.input", side_effect=answers) as prompt,
              patch.object(dev_server, "cli", side_effect=run)):
            dev_server.restart_if_requested("gft", Path("/tmp/selected.json"),
                {"GRAFFITTY_SOCKET": "other-owner", "GRAFFITTY_TOKEN": "other-token"})
        return prompt

    def test_keep_default_eof_and_noninteractive_do_nothing(self):
        for answers in ([""], ["1"], [EOFError()]):
            self.invoke(answers)
            self.assertEqual(self.commands, [])
        prompt = self.invoke([], interactive=False)
        prompt.assert_not_called()
        self.assertEqual(self.commands, [])

    def test_changed_owner_is_left_alone(self):
        self.invoke(["2"], owners=[{"pid": 42}, {"pid": 43}])
        self.assertEqual(self.commands, [])

    def test_changed_owner_after_checkpoint_aborts(self):
        with self.assertRaisesRegex(RuntimeError, "Server changed"):
            self.invoke(["3", "RESTART"], owners=[{"pid": 42}, {"pid": 42}, {"pid": 43}])
        self.assertNotIn(("server", "restart"), self.commands)
        self.assertFalse(any(c[:2] == ("session", "kill") for c in self.commands))

    def test_safe_restart_saves_checkpoint_and_never_closes_sessions(self):
        self.invoke(["invalid", "2"])
        self.assertEqual(self.commands, [
            ("session", "list", "--json"), ("checkpoint", "save"),
            ("server", "restart"), ("session", "list", "--json"),
        ])

    def test_destructive_choice_requires_exact_confirmation(self):
        for confirmation in ("", "yes", "restart", EOFError()):
            self.invoke(["3", confirmation])
            self.assertEqual(self.commands, [])

    def test_reset_creates_fresh_session_before_closing_only_original_sessions(self):
        self.invoke(["3", "RESTART"])
        self.assertEqual(self.commands, [
            ("session", "list", "--json"), ("checkpoint", "save"),
            ("server", "restart"), ("session", "list", "--json"),
            ("session", "new", "-d"), ("session", "kill", "-t", "$1"),
            ("session", "list", "--json"),
        ])

    def test_failed_checkpoint_restart_or_fresh_session_never_closes_sessions(self):
        for command in ("checkpoint", "server restart", "session new"):
            with self.subTest(command=command), self.assertRaises(RuntimeError):
                self.invoke(["3", "RESTART"], fail=command)
            self.assertFalse(any(c[:2] == ("session", "kill") for c in self.commands))

    def test_missing_sessions_after_handover_aborts(self):
        with self.assertRaisesRegex(RuntimeError, "did not survive"):
            self.invoke(["3", "RESTART"], after=[])
        self.assertFalse(any(c[:2] in (("session", "new"), ("session", "kill")) for c in self.commands))

    def test_invalid_session_response_is_rejected(self):
        for value in ({}, [{"id": "project"}], [{"id": None}], [3]):
            with patch.object(dev_server, "cli", return_value=json.dumps(value)):
                with self.assertRaisesRegex(RuntimeError, "Invalid session list"):
                    dev_server.session_ids("gft", {})


if __name__ == "__main__":
    unittest.main()
