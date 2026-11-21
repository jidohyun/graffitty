"""Pi's in-process integration contracts, without credentials or paid model calls."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_opencode_integration as shared

BIN = shared.BIN


class PiIntegration(unittest.TestCase):
    cli = shared.OpenCodeIntegration.cli
    serve = shared.OpenCodeIntegration.serve
    publish = shared.OpenCodeIntegration.publish
    stop_server = shared.OpenCodeIntegration.stop_server
    next = shared.OpenCodeIntegration.next
    start = shared.OpenCodeIntegration.start
    plugin = shared.OpenCodeIntegration.plugin
    plugin_directory = shared.OpenCodeIntegration.plugin_directory
    lifecycle = shared.OpenCodeIntegration.lifecycle

    def setUp(self):
        shared.OpenCodeIntegration.setUp(self)
        self.provider = "pi"
        self.env["PI_CODING_AGENT_DIR"] = str(self.home / "pi")

    reply = shared.OpenCodeIntegration.reply

    def snapshot(self, events=(), entries=(), session="pi-session", idle=True, **extra):
        return dict(sessionID=session, pid=os.getpid(), sessionFile="/tmp/pi-session.jsonl",
                    header={"type": "session", "id": session, "version": 3}, entries=list(entries), events=list(events),
                    idle=idle, pending=False, waiting=False, **extra)

    @staticmethod
    def message(role, text, **extra):
        return {"type": "message_end", "message": {"role": role, "content": [{"type": "text", "text": text}], **extra}}

    def test_install_idempotent_preview_remove_and_foreign_directory(self):
        home = Path(self.env["PI_CODING_AGENT_DIR"])
        self.assertEqual(self.cli("integrate", "agent", "pi").returncode, 0)
        self.assertFalse(home.exists())
        self.assertNotEqual(self.cli("integrate", "agent", "pi", "--status").returncode, 0)
        home.mkdir()
        other = home / "settings.json"
        other.write_text('{"keep":true}')
        self.assertEqual(self.cli("integrate", "agent", "pi", "--apply").returncode, 0)
        files = {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
        self.assertEqual(self.cli("integrate", "agent", "pi", "--apply").returncode, 0)
        self.assertEqual(files, {p: p.read_bytes() for p in home.rglob("*") if p.is_file()})
        self.assertEqual(self.cli("integrate", "agent", "pi", "--status").returncode, 0)
        self.assertEqual(self.cli("integrate", "agent", "pi", "--remove", "--apply").returncode, 0)
        self.assertEqual(other.read_text(), '{"keep":true}')
        foreign = home / "extensions/graffitty/index.ts"
        foreign.parent.mkdir(parents=True)
        foreign.write_text("user-owned")
        self.assertNotEqual(self.cli("integrate", "agent", "pi", "--apply").returncode, 0)
        self.assertEqual(foreign.read_text(), "user-owned")

    def test_only_live_settled_events_complete_and_preserve_native_history(self):
        old = {"id": "old", "type": "message", "message": self.message("assistant", "old answer")["message"]}
        request = self.reply(self.start(), self.snapshot(entries=[old]))
        self.assertFalse(self.lifecycle("Stop"))
        for n in range(2):
            request = self.reply(request, self.snapshot([self.message("user", "same question"), self.message("assistant", "same answer"), {"type": "agent_end"}], idle=False))
            self.assertEqual(len(self.lifecycle("Stop")), n)
            request = self.reply(request, self.snapshot([{"type": "agent_settled", "id": str(n), "aborted": False}]))
        self.assertEqual([e["text"] for e in self.lifecycle("Stop")], ["same answer", "same answer"])
        request = self.reply(request, self.snapshot([self.message("user", "failed prompt"), self.message("assistant", "", stopReason="error", errorMessage="API rate limit reached"), {"type": "agent_settled", "id": "error"}]))
        self.assertEqual(self.lifecycle("Stop")[-1]["text"], "API rate limit reached")
        self.assertEqual(self.lifecycle("Stop")[-1]["outcome"], "error")
        request = self.reply(request, self.snapshot([self.message("user", "cancel this"), self.message("assistant", "", stopReason="aborted"), {"type": "agent_settled", "id": "cancelled", "aborted": True}]))
        self.assertEqual(self.lifecycle("Stop")[-1]["outcome"], "interrupted")
        start = self.lifecycle("SessionStart")[0]
        self.assertEqual((start["kind"], start["provider"], start["transport"]), ("agent", "pi", "inbox"))
        # Pi declares its own relaunch: this exact session file and agent directory.
        restore = start["restore"]
        self.assertEqual((Path(restore["command"][0]).name, restore["command"][1:]), ("pi", ["--session", "/tmp/pi-session.jsonl"]))
        self.assertEqual(restore["env"], {"PI_CODING_AGENT_DIR": self.env["PI_CODING_AGENT_DIR"], "PI_CODING_AGENT_SESSION_DIR": None})
        path = Path(start["transcript_path"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text().splitlines()[1]), old)
        context = self.plugin("context")
        self.assertEqual(context.returncode, 0, context.stderr)
        self.assertIn("Current graph", context.stdout)
        for method in ("graph.read", "graph.send"):
            result = self.plugin("tool", input={"method": method, "params": {"node": "%2", "to": "%2", "text": "reply"}})
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.plugin("tool", input={"method": "graph.connect"}).returncode, 0)

    def test_typing_defers_new_work_until_the_server_gate_opens(self):
        request = self.reply(self.start(), self.snapshot())
        self.queue = [{"event_id": "quiet", "source": "%2", "target": "%1", "text": "after typing"}]
        self.typing = True
        request = self.reply(request, self.snapshot())
        self.assertEqual(request["op"], "snapshot")
        self.assertFalse(any(r["method"] == "graph.ack" for r in self.requests))
        self.typing = False
        request = self.reply(request, self.snapshot())
        self.assertEqual(request["op"], "prompt")
        self.reply(request, {"accepted": True})

    def test_busy_queue_is_revocable_and_ack_requires_user_message(self):
        request = self.reply(self.start(), self.snapshot())
        event = {"event_id": "revoked", "source": "%2", "target": "%1", "run_id": "causal-run", "text": "Implement it", "sessions": []}
        self.queue = [event]
        request = self.reply(request, self.snapshot(idle=False))
        self.assertEqual(request["op"], "snapshot")
        self.queue = []
        request = self.reply(request, self.snapshot())
        self.assertEqual(request["op"], "snapshot")
        self.queue = [{**event, "event_id": "live"}]
        request = self.reply(request, self.snapshot())
        self.assertEqual(request["op"], "prompt")
        prompt = request["text"]
        self.assertIn("run causal-run]", prompt)
        request = self.reply(request, {"accepted": True})
        self.assertFalse(any(r["method"] == "graph.ack" for r in self.requests))
        request = self.reply(request, self.snapshot(idle=False))
        self.assertEqual(request["op"], "snapshot")
        self.queue[0]["sessions"] = [{"provider": "claude", "id": "peer-session"}]
        self.reply(request, self.snapshot([self.message("user", prompt)], idle=False))
        self.assertEqual([r["params"]["event_id"] for r in self.requests if r["method"] == "graph.ack"], ["live"])

    def test_dispatch_rechecks_busy_state_and_session_switch_ends_old_lifecycle(self):
        request = self.reply(self.start(), self.snapshot())
        self.queue = [{"event_id": "retry", "text": "hello"}]
        request = self.reply(request, self.snapshot())
        self.assertEqual(request["op"], "prompt")
        request = self.reply(request, {"accepted": False})
        self.assertFalse(any(r["method"] == "graph.ack" for r in self.requests))
        self.queue = []
        request = self.reply(request, self.snapshot(session="pi-other"))
        self.assertEqual([e["session_id"] for e in self.lifecycle("SessionStart")], ["pi-session", "pi-other"])
        self.assertEqual(len(self.lifecycle("SessionEnd")), 1)
        self.assertFalse(self.lifecycle("Stop"))
        self.child.stdin.write(json.dumps({"id": request["id"], "result": self.snapshot([self.message("assistant", "last reply"), {"type": "agent_settled", "id": "last"}], session="pi-other", closing=True)}) + "\n")
        self.child.stdin.flush()
        self.assertEqual(self.child.wait(5), 0)
        self.assertEqual(self.lifecycle("Stop")[-1]["text"], "last reply")
        self.assertEqual(len(self.lifecycle("SessionEnd")), 2)
        self.child.stdin.close(); self.child.stdout.close(); self.child.stderr.close()


if __name__ == "__main__":
    unittest.main()
