#!/usr/bin/env python3
"""Test `gft pane run` and `gft pane place` from a live pane on a private headless server.

- A new pane records its parent and can land beside it or at an absolute position.
- `gft pane place` also works on an existing pane.
- Children close with their parent unless launched with `--outlive-parent`.
- The server rejects tab-scoped placement.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client  # noqa: E402


def pane(client, pane_id):
    return next(p for p in client.topology["panes"] if p["id"] == pane_id)


def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix="gr-run-") as tmp:
        tmp = Path(tmp)
        path = tmp / "server.json"
        env = dict(os.environ, SHELL="/bin/sh")
        env.pop("DISPLAY", None)
        server = subprocess.Popen(
            [BINARY, "server", "--listen", "127.0.0.1:0", "--connection", path, "--auth-file", tmp / "auth.json"],
            env=env, stdout=subprocess.DEVNULL, stderr=(tmp / "server.log").open("w"),
        )
        try:
            for _ in range(200):
                if path.exists():
                    break
                assert server.poll() is None, (tmp / "server.log").read_text()
                time.sleep(0.05)
            client = Client(json.loads(path.read_text()), "alpha")
            root = client.topology["panes"][0]["id"]
            client.has_output(root, "$")
            # A program beside the caller: the parent link and the placement.
            client.text(root, f'"$GRAFFITTY_BIN" pane run --name build --side right -- "printf SPAWNED_OK; exec sh" > {tmp}/run.json; echo RUN_DONE\r')
            client.has_output(root, "RUN_DONE")
            result = json.loads((tmp / "run.json").read_text())["result"]
            child = int(result["pane"][1:])
            assert result["spawned_by"] == f"%{root}" and result["dies_with_parent"] is True, result
            client.until(lambda: any(p["id"] == child for p in client.topology["panes"]))
            client.until(lambda: pane(client, child).get("spawned_by") == root)
            parent_rect, child_rect = pane(client, root)["rect"], pane(client, child)["rect"]
            assert child_rect[0] >= parent_rect[0] + parent_rect[2] and abs(child_rect[1] - parent_rect[1]) < 1, (parent_rect, child_rect)
            assert pane(client, child)["title"] == "build", pane(client, child)["title"]
            client.has_output(child, "SPAWNED_OK")
            checks.append("run places a named child beside its parent and records spawned_by")
            # Absolute placement needs a floating tab; new tabs start tiled.
            state = client.topology["workspace_state"]
            tab = pane(client, root)["tab"]
            layout = dict(state["layout"]["tabs"][str(tab)], enabled=False)
            client.messages.clear()
            client.action("workspace_edit", root, request=1, expected_revision=state["revision"], edit={"op": "tab", "tab": tab, "layout": layout, "settings": None})
            client.until(lambda: any(m.get("type") in ("ack", "error") and m.get("request") == 1 for m in client.messages))
            assert any(m.get("type") == "ack" and m.get("request") == 1 for m in client.messages), client.messages[-3:]
            client.until(lambda: not client.topology["workspace_state"]["layout"]["tabs"][str(tab)]["enabled"])
            # Absolute placement and a size, then rearranging with place.
            client.text(root, f'"$GRAFFITTY_BIN" pane run --outlive-parent --at 40,900 --size 600x300 > {tmp}/free.json; echo FREE_DONE\r')
            client.has_output(root, "FREE_DONE")
            free = int(json.loads((tmp / "free.json").read_text())["result"]["pane"][1:])
            client.until(lambda: any(p["id"] == free and p["rect"] == [40.0, 900.0, 600.0, 300.0] for p in client.topology["panes"]))
            client.text(root, f'"$GRAFFITTY_BIN" pane place --target %{free} --side below --of %{child} > {tmp}/place.json; echo PLACE_DONE\r')
            client.has_output(root, "PLACE_DONE")
            placed = json.loads((tmp / "place.json").read_text())
            assert "result" in placed, placed
            client.until(lambda: pane(client, free)["rect"][1] >= child_rect[1] + child_rect[3] and abs(pane(client, free)["rect"][0] - child_rect[0]) < 1)
            checks.append("run --at/--size and place --side arrange floating panes")
            # Placement never leaves the caller's tab.
            client.action("create", root, kind="tab")
            client.until(lambda: len(client.topology["tabs"]) == 2)
            other = next(p["id"] for p in client.topology["panes"] if p["tab"] != pane(client, root)["tab"])
            client.text(root, f'"$GRAFFITTY_BIN" pane place --target %{other} --side right > {tmp}/foreign.json; echo FOREIGN_DONE\r')
            client.has_output(root, "FOREIGN_DONE")
            assert json.loads((tmp / "foreign.json").read_text())["error"]["code"] == "forbidden"
            checks.append("placement in another tab is refused")
            # Closing the parent ends the dependent child; the survivor forgets it.
            client.action("close", root)
            client.until(lambda: all(p["id"] != child for p in client.topology["panes"]))
            client.until(lambda: pane(client, free).get("spawned_by") is None)
            assert any(p["id"] == free for p in client.topology["panes"])
            checks.append("children close with their parent unless --outlive-parent")
            client.ws.close()
        finally:
            server.terminate()
            server.wait(timeout=10)
    for check in checks:
        print("PASS", check)
    print("TERMINAL_RUN_E2E_PASS")


if __name__ == "__main__":
    main()
