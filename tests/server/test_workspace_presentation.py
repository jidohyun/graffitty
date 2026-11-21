"""The session owner shares layout areas and ignores frontend world metadata."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from test_session_transfer import Peer, PrivateServer


class WorkspacePresentationTests(unittest.TestCase):
    def test_tabs_share_layout_without_storing_world_choices(self):
        with tempfile.TemporaryDirectory(prefix="gr-tab-world-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                peer = Peer(json.loads(owner.descriptor.read_text())["local"])
                try:
                    source = peer.topology["panes"][0]["id"]
                    state = peer.sync()["workspace_state"]
                    settings = dict(state["tabs"][str(source)], area=[0, 34, 1600, 966])
                    # Frontend-only metadata has no meaning in the session owner.
                    presentation = dict(settings, world="bistro")
                    edited = peer.action("workspace_edit", expected_revision=state["revision"],
                        edit=dict(op="tab", tab=source, layout=state["layout"]["tabs"][str(source)], settings=presentation))
                    self.assertEqual(edited["type"], "ack", edited)
                    child = peer.action("create", source, kind="tab")["created"]
                    split = peer.action("create", child, kind="pane")["created"]
                    grandchild = peer.action("create", split, kind="tab")["created"]
                    topology = peer.sync()
                    state = topology["workspace_state"]
                    for tab in (source, child, grandchild):
                        self.assertEqual(state["tabs"][str(tab)], settings)
                    for tab in topology["tabs"]:
                        self.assertNotIn("plugin", tab)
                        self.assertNotIn("world", tab)
                        self.assertNotIn("layout", tab)
                        self.assertNotIn("area", tab)
                    self.assertEqual(len(state["layout"]["tabs"][str(child)]["windows"]), 2)
                    resized = dict(settings, area=[0, 34, 1000, 666])
                    self.assertEqual(peer.action("workspace_edit", expected_revision=state["revision"],
                        edit=dict(op="tab", tab=source, layout=state["layout"]["tabs"][str(source)], settings=resized))["type"], "ack")
                    resized_child = peer.action("create", source, kind="tab")["created"]
                    state = peer.sync()["workspace_state"]
                    self.assertEqual(state["tabs"][str(resized_child)], resized)
                    self.assertEqual(state["tabs"][str(child)], settings)
                finally:
                    peer.socket.close()


if __name__ == "__main__":
    unittest.main()
