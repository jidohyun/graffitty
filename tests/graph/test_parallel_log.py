# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1"]
# ///
"""Parallel image/log controls over a real PTY and Godot graph socket."""
import fcntl
import os
import pty
import select
import struct
import termios
import time
import unittest

import pyte
import test_filter_node as fixtures
from test_parallel_node import ROOT, stop, wait


class ParallelLogIntegration(unittest.TestCase):
    setUp = fixtures.FilterIntegration.setUp
    tearDown = fixtures.FilterIntegration.tearDown
    start = fixtures.FilterIntegration.start
    call = fixtures.FilterIntegration.call

    def drain(self):
        while select.select([self.master], [], [], 0)[0]:
            data = os.read(self.master, 65536)
            if not data:
                break
            self.stream.feed(data)
        text = "\n".join(self.screen.display)
        if self.node.poll() is not None:
            self.fail(f"Parallel exited ({self.node.returncode}):\n{text}")
        return text

    def send(self, data):
        os.write(self.master, data)

    def inbox(self, token):
        # Keep consuming terminal output while waiting on the separate graph socket.
        self.drain()
        return self.call(token, "graph.take")["events"]

    def click(self, label):
        self.drain()
        y = next(i for i, row in enumerate(self.screen.display) if label in row)
        x = self.screen.display[y].index(label)
        self.send(f"\x1b[<0;{x+1};{y+1}M\x1b[<0;{x+1};{y+1}m".encode())

    def resize(self, columns, rows):
        self.screen.resize(lines=rows, columns=columns)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def test_toggle_payloads_scroll_and_delivery_in_both_views(self):
        self.master, slave = pty.openpty()
        self.addCleanup(os.close, self.master)
        self.addCleanup(os.close, slave)
        original_modes = termios.tcgetattr(slave)
        self.screen = pyte.Screen(100, 32)
        # Answer terminal queries as the real Graffitty terminal does.
        self.screen.write_process_input = lambda data: self.send(data.encode())
        self.stream = pyte.ByteStream(self.screen)
        self.resize(100, 32)
        node = self.start(
            [str(ROOT / "dist/bin/gft"), "node", "parallel", "--name", "Review join"],
            {**self.env, "TERM": "xterm-256color"}, stdin=slave, stdout=slave, stderr=slave,
        )
        self.node = node
        self.addCleanup(stop, node)
        wait(lambda: "[ Show log ]" in self.drain())
        self.assertIn("PARALLEL JOIN", self.drain())
        self.click("[ Show log ]")
        wait(lambda: "Waiting for input…" in self.drain())
        self.assertIn("Delivery log · local time", self.drain())
        self.send(b"l")
        wait(lambda: "[ Show log ]" in self.drain())

        self.call(2, "agent.event", provider="adapter", event="SessionStart", session_id="second")
        self.call(2, "agent.register", name="Second", inputs=[], outputs=[{"id": "result"}])
        for source in (1, 2):
            self.call(source, "graph.connect", **{"from": f"%{source}", "from_port": "result", "to": "%3", "to_port": "join"})
        self.call(3, "graph.connect", **{"from": "%3", "from_port": "combined", "to": "%4", "to_port": "in"})
        first_payload = {"text": "first payload", "custom": {"nested": [True, None, "café"]}}
        self.call(1, "graph.emit", output="result", payload=first_payload)
        wait(lambda: "1/2  50%" in self.drain())
        self.assertEqual(self.call(4, "graph.take")["events"], [])
        self.call(2, "graph.emit", output="result", payload={"text": "second payload"})
        events = wait(lambda: self.inbox(4))
        self.assertEqual(events[0]["payload"]["inputs"][0]["payload"], first_payload)
        wait(lambda: not self.inbox(3))

        # Events received while the image was visible remain available in the log.
        self.send(b"l")
        wait(lambda: "[ Show image ]" in self.drain())
        self.send(b"\x1b[H")  # Home
        wait(lambda: "IN · round 1" in self.drain())
        self.assertRegex(self.drain(), r"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}\] IN")
        top_line = self.screen.display[4]
        self.send(b"\x1b[<65;10;10M")  # Wheel down inside the log
        wait(lambda: self.drain().splitlines()[4] != top_line)
        wheel_line = self.screen.display[4]
        self.send(b"\x1b[6~")  # Page Down
        wait(lambda: self.drain().splitlines()[4] != wheel_line)
        self.send(b"\x1b[F")  # End
        wait(lambda: '"parallel.completed"' in self.drain())

        # Fit the complete history to check distinct entries and unmodified payloads.
        self.resize(160, 300)
        # The node reads the new size at its next draw. The last entry is
        # already on the small screen, so wait for the first one, which only
        # the large one shows.
        wait(lambda: self.drain().count("] IN · round 1") == 2)
        log = self.drain()
        self.assertIn("OUT · round 1 · Combined · queued", log)
        self.assertEqual(log.count("] IN · round 1"), 2)
        self.assertEqual(log.count("] OUT · round 1"), 1)
        self.assertIn('"nested": [', log)
        self.assertIn('"café"', log)
        self.assertIn('"event_id":', log)
        self.assertIn('"run_id":', log)
        self.assertIn('"output": "combined"', log)
        self.assertIn('"sessions":', log)
        time.sleep(.7)
        self.assertEqual(self.drain().count("] IN · round 1"), 2, "Polling must not duplicate IN entries")

        # The next round completes with the log visible too.
        for source in (1, 2):
            self.call(source, "graph.emit", output="result", payload={"text": f"next {source}"})
        wait(lambda: len(self.inbox(4)) == 2)
        wait(lambda: "OUT · round 2 · Combined · queued" in self.drain())
        self.click("[ Show image ]")
        wait(lambda: "PARALLEL JOIN" in self.drain())
        self.resize(60, 16)
        wait(lambda: "[ Show log ]" in self.drain())
        self.click("[ Show log ]")
        wait(lambda: "Delivery log · local time" in self.drain())
        self.send(b"\x03")
        node.wait(timeout=10)
        self.assertEqual(node.returncode, 0)
        self.assertEqual(termios.tcgetattr(slave), original_modes)
        nodes = self.call(1, "graph.list")["nodes"]
        self.assertEqual(next(n for n in nodes if n["node"] == "%3")["status"], "offline")


if __name__ == "__main__":
    unittest.main()
