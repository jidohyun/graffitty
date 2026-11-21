# /// script
# dependencies = ["websocket-client"]
# ///
"""Real owner requests: tabs bound graph authority and connected-group transfers."""
import json
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from e2e_server import PrivateServer
from test_session_transfer import Peer


class GraphTabBoundaryTests(unittest.TestCase):
    def test_reject_cross_tab_links_and_move_complete_component(self):
        with tempfile.TemporaryDirectory(prefix="gft-graph-tabs-") as folder:
            directory = Path(folder)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_",))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                peer = Peer(json.loads(owner.descriptor.read_text())["local"], "graph-tabs", new=True)
                try:
                    first = peer.topology["panes"][0]["id"]
                    second, third, unrelated = [peer.action("create", first, kind="pane")["created"] for _ in range(3)]
                    other = peer.action("create", kind="tab")["created"]
                    def rpc(pane, method, **params):
                        return peer.action("rpc", pane, method=method, params=params)
                    for pane in (first, second, third, unrelated, other):
                        self.assertNotIn("error", rpc(pane, "agent.event", provider="adapter", event="SessionStart"))
                        self.assertNotIn("error", rpc(pane, "agent.register", name="Test", inputs=[{"id": "in"}], outputs=[{"id": "out"}]))
                    def connect(a, b, **flags):
                        return rpc(first, "graph.connect", **{"from": f"%{a}", "to": f"%{b}", "from_port": "out", "to_port": "in", **flags})
                    before = rpc(first, "graph.list")["result"]
                    for a, b in ((first, other), (other, first), (second, other)):
                        rejected = connect(a, b)
                        self.assertIn("error", rejected, rejected)
                        self.assertIn("one tab", rejected["error"]["message"])
                    self.assertEqual(rpc(first, "graph.list")["result"]["edges"], before["edges"])
                    self.assertNotIn("error", connect(first, second))
                    self.assertNotIn("error", connect(third, second, muted=True))
                    self.assertNotIn("error", connect(third, first))  # cycle, reverse traversal
                    graph = rpc(first, "graph.list")["result"]["edges"]
                    state = peer.action("workspace_get")["workspace_state"]
                    source_tab = next(p["tab"] for p in peer.sync()["panes"] if p["id"] == first)
                    layout = state["layout"]["tabs"][str(source_tab)]
                    layout["enabled"] = False
                    for index, window in enumerate(layout["windows"]):
                        window["rect"] = [80.0 + index * 550, 120.0 + index * 90, 400.0, 300.0]
                    reply = peer.action("workspace_edit", expected_revision=state["revision"], edit=dict(op="tab", tab=source_tab, layout=layout))
                    self.assertEqual(reply["type"], "ack", reply)
                    before = peer.sync()
                    original = {p["id"]: p for p in before["panes"]}
                    # Reject bad targets without partially moving the graph.
                    self.assertEqual(peer.action("regroup", surface=f"%{second}", tab=999999)["type"], "error")
                    self.assertEqual({p["id"]: p["tab"] for p in peer.sync()["panes"]}, {p: v["tab"] for p, v in original.items()})
                    moved = peer.action("regroup", surface=f"%{second}", tab=other)
                    self.assertNotEqual(moved["type"], "error", moved)
                    panes = {p["id"]: p for p in peer.sync()["panes"]}
                    for pane in (first, second, third):
                        self.assertEqual(panes[pane]["tab"], other)
                        self.assertEqual(panes[pane]["pid"], original[pane]["pid"])
                        self.assertEqual(panes[pane]["rect"], original[pane]["rect"])
                    self.assertEqual(panes[unrelated]["tab"], original[unrelated]["tab"])
                    self.assertEqual(rpc(first, "graph.list")["result"]["edges"], graph)
                    self.assertIn("error", connect(first, unrelated))
                    # Moving into a new tab carries the same complete component.
                    new = peer.action("regroup", surface=f"%{third}")
                    self.assertNotEqual(new["type"], "error", new)
                    panes = {p["id"]: p for p in peer.sync()["panes"]}
                    self.assertEqual(len({panes[p]["tab"] for p in (first, second, third)}), 1)
                    self.assertNotEqual(panes[first]["tab"], other)
                    self.assertEqual(panes[other]["tab"], other)
                finally:
                    peer.socket.close()


class GraphGroupPreviewTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot is required for the real drag preview")
    def test_preview_and_drop_match_with_tiling_and_physics(self):
        with tempfile.TemporaryDirectory(prefix="gft-group-preview-") as folder:
            directory = Path(folder)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GRAFFITTY_",))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            env["SHELL"] = "/bin/sh"
            with PrivateServer(env, directory, "/bin/sh") as owner:
                env["GRAFFITTY_BIN"] = str(owner.binary)
                result = subprocess.run(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                    "--script", "tests/graph_group_transfer_smoke.gd", "--", "--shell=/bin/sh"],
                    env=env, capture_output=True, text=True, timeout=60)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertNotIn("SCRIPT ERROR", output)
                self.assertIn("GRAPH_GROUP_TRANSFER failures=[]", output)


if __name__ == "__main__":
    unittest.main()
