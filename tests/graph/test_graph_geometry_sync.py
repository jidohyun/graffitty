"""Committed graph positions are pushed to peers and survive reconnects."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/server",)]
from test_size_claims import PrivateServer, PrivateClient


class GraphGeometrySyncTests(unittest.TestCase):
    def test_move_broadcast_reconnect_conflict_and_undo(self):
        with tempfile.TemporaryDirectory(prefix="gr-graph-sync-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                descriptor = json.loads(owner.descriptor.read_text())["local"]
                mac = PrivateClient(descriptor)
                phone = reconnect = None
                try:
                    mac.action("create", -1, kind="tab")
                    topology = mac.until(lambda m: m.get("type") == "topology" and m["tabs"])
                    tab = topology["tabs"][0]["id"]
                    phone = PrivateClient(descriptor)
                    state = phone.topology["workspace_state"]
                    layout = copy.deepcopy(state["layout"]["tabs"][str(tab)])
                    key = layout["windows"][0]["key"]
                    graph = {"routes": {f"{key}/out>{key}/in": ["bend"]}, "reroutes": {"bend": {"position": [400, 250]}}}
                    layout["graph_visual"] = graph
                    layout["windows"][0]["rect"][0] = 550
                    reply = phone.action("workspace_edit", expected_revision=state["revision"], edit=dict(op="tab", tab=tab, layout=layout))
                    self.assertEqual(reply["type"], "ack", reply)
                    # No sync/poll request: the other connection receives the push.
                    pushed = mac.until(lambda m: m.get("type") == "topology" and m["workspace_state"]["layout"]["tabs"][str(tab)].get("graph_visual") == graph)
                    self.assertEqual(pushed["workspace_state"]["layout"]["tabs"][str(tab)]["windows"][0]["rect"][0], 550)
                    stale = mac.action("workspace_edit", expected_revision=state["revision"], edit=dict(op="tab", tab=tab, layout=layout))
                    self.assertEqual(stale["type"], "error")
                    reconnect = PrivateClient(descriptor)
                    self.assertEqual(reconnect.topology["workspace_state"]["layout"]["tabs"][str(tab)]["graph_visual"], graph)
                    undone = phone.action("workspace_edit", expected_revision=reply["workspace_state"]["revision"], edit=dict(op="undo"))
                    self.assertEqual(undone["type"], "ack", undone)
                    mac.until(lambda m: m.get("type") == "topology" and not m["workspace_state"]["layout"]["tabs"][str(tab)]["graph_visual"]["reroutes"])
                finally:
                    for peer in (mac, phone, reconnect):
                        if peer is not None: peer.socket.close()


if __name__ == "__main__":
    unittest.main()
