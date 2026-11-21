"""Two frontends on one workspace: the latest claim sizes the shared main area."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient


def tab_role(message):
    return message["tabs"][0].get("size_owner")


class SizeClaimTests(unittest.TestCase):
    def test_latest_claim_wins_and_a_departure_hands_nothing_over(self):
        with tempfile.TemporaryDirectory(prefix="gr-size-claims-") as tmp:
            directory = Path(tmp).resolve()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "pwsh.exe" if os.name == "nt" else "/bin/sh") as owner:
                local = json.loads(owner.descriptor.read_text())["local"]
                desktop = PrivateClient(local, "main")
                desktop.action("create", -1, kind="tab")
                desktop.until(lambda m: m.get("type") == "topology" and m["tabs"])
                phone = PrivateClient(local, "main")
                try:
                    tab = phone.topology["tabs"][0]["id"]
                    self.assertEqual(tab_role(phone.topology), "none")

                    def claim(peer, area, claim=True):
                        state = peer.action("workspace_get")["workspace_state"]
                        edit = {"op": "tab", "tab": tab, "layout": state["layout"]["tabs"][str(tab)], "settings": {"area": area}}
                        reply = peer.action("workspace_edit", expected_revision=state["revision"], edit=edit, claim=claim)
                        self.assertEqual(reply["type"], "ack", reply)

                    def seen(peer, role, area):
                        return peer.until(lambda m: m.get("type") == "topology" and tab_role(m) == role
                                          and m["workspace_state"]["tabs"][str(tab)]["area"] == area)

                    narrow, wide = [0, 34, 412, 846], [0, 34, 1440, 866]
                    claim(phone, narrow)
                    narrow_columns = seen(phone, "self", narrow)["panes"][0]["columns"]
                    seen(desktop, "other", narrow)
                    claim(desktop, wide)
                    wide_columns = seen(desktop, "self", wide)["panes"][0]["columns"]
                    seen(phone, "other", wide)
                    self.assertGreater(wide_columns, narrow_columns, "The owner PTY follows the claimed area")
                    # A plain layout edit from a non-owner keeps the claim where it is.
                    claim(phone, wide, claim=False)
                    phone.send({"type": "sync", "session": -1, "request": 999})
                    self.assertEqual(tab_role(phone.until(lambda m: m.get("type") == "topology")), "other")
                    desktop.socket.close()
                    after = seen(phone, "none", wide)
                    self.assertEqual(after["panes"][0]["columns"], wide_columns, "A departure leaves the area as it was")
                finally:
                    phone.socket.close()
                    try: desktop.socket.close()
                    except OSError: pass


if __name__ == "__main__":
    unittest.main()
