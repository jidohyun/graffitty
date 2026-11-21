"""Explicit hook actions, independent of provider installs or model calls."""
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import unittest


BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", Path(__file__).resolve().parents[2] / "dist/bin" / ("gft.exe" if os.name == "nt" else "gft")))
HOOKS = {
    "session-start": "SessionStart", "prompt-submit": "UserPromptSubmit",
    "turn-end": "Stop", "session-end": "SessionEnd", "tool-start": "PreToolUse",
    "permission-request": "PermissionRequest", "tool-end": "PostToolUse",
}


class Callbacks(unittest.TestCase):
    def run_callback(self, action, provider="claude", payload="not-json", extra=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "PI_", "CODEX_", "CLAUDE_"))}
        env.update(extra or {})
        return subprocess.run([BIN, "internal", "agent-hook-integrate", action, "--provider", provider],
                              input=payload, env=env, capture_output=True, text=True, timeout=10)

    def test_all_callbacks_noop_without_pane_capability(self):
        for provider in ("codex", "claude", "pi", "opencode"):
            for action in HOOKS:
                with self.subTest(provider=provider, action=action):
                    result = self.run_callback(action, provider)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_mismatched_event_is_rejected_before_contacting_server(self):
        for provider in ("codex", "claude", "pi", "opencode"):
            payload = {"event" if provider in ("pi", "opencode") else "hook_event_name": "Stop"}
            result = self.run_callback("tool-start", provider, json.dumps(payload),
                                       {"GRAFFITTY_SOCKET": "tcp://127.0.0.1:1", "GRAFFITTY_TOKEN": "test"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match", result.stderr)

    def test_callbacks_forward_events_and_refresh_tool_context(self):
        for action, event in (HOOKS | {"turn-error": "StopFailure"}).items():
            with self.subTest(action=action), socket.socket() as server:
                server.bind(("127.0.0.1", 0))
                server.listen(1)
                server.settimeout(10)
                received = []

                def respond():
                    with server.accept()[0] as peer:
                        request = json.loads(peer.makefile("rb").readline())
                        received.append(request)
                        peer.sendall((json.dumps({"id": request["id"], "result": {
                            "adjacent": {}, "graph_changed": True}}) + "\n").encode())

                thread = threading.Thread(target=respond)
                thread.start()
                result = self.run_callback(action, payload=json.dumps({
                    "hook_event_name": event, "session_id": "fixture",
                    "error": "rate_limit", "error_details": "API quota exceeded"}), extra={
                    "GRAFFITTY_SOCKET": f"tcp://127.0.0.1:{server.getsockname()[1]}",
                    "GRAFFITTY_TOKEN": "test"})
                thread.join(12)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(received), 1)
                self.assertEqual(received[0]["method"], "agent.event")
                self.assertEqual(received[0]["params"]["event"], "Error" if event == "StopFailure" else event)
                if event == "StopFailure":
                    self.assertEqual(received[0]["params"]["outcome"], "error")
                    self.assertEqual(received[0]["params"]["text"], "API quota exceeded")
                self.assertEqual(received[0]["token"], "test")
                if action in ("session-start", "prompt-submit", "tool-start", "tool-end"):
                    self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["hookEventName"], event)
                else:
                    self.assertEqual(json.loads(result.stdout), {})

    def test_obsolete_entrypoint_is_rejected(self):
        for command in ("integration-event", "integrate"):
            result = subprocess.run([BIN, "internal", command, "--help"], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
