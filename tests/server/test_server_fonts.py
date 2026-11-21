"""Font files, metrics and PTY wrapping are owned by the server."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from test_session_transfer import Peer


class ServerFontTests(unittest.TestCase):
    def test_font_geometry_assets_and_two_clients(self):
        with tempfile.TemporaryDirectory(prefix="graffitty-font-e2e-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            env.update(XDG_CONFIG_HOME=str(directory / "config"), XDG_STATE_HOME=str(directory / "state"))
            config = directory / "config/graffitty/server.toml"
            config.parent.mkdir(parents=True)
            # Explicit file proves server paths are resolved relative to TOML,
            # and clients can fetch that file without having the path installed.
            source = ROOT / "frontends/godot/extension/fonts/JetBrainsMonoNerdFont-Regular.ttf"
            font = source.read_bytes()
            (config.parent / "private.ttf").write_bytes(font)
            config.write_text('[terminal]\nlogin_shell=false\n[terminal.font]\nsize=20\npaths=["private.ttf"]\n')
            with PrivateServer(env, directory, "pwsh.exe" if os.name == "nt" else "/bin/sh") as owner:
                descriptor = json.loads(owner.descriptor.read_text())["local"]
                first = Peer(descriptor, "font-test", new=True)
                second = Peer(descriptor, first.workspace)
                try:
                    pane = first.topology["panes"][0]
                    identifier, pid = pane["id"], pane["pid"]
                    self.assertEqual(pane["font_size"], 20)
                    self.assertEqual(first.topology["terminal_font"], second.topology["terminal_font"])
                    manifest = first.topology["terminal_font"]["faces"][0]
                    self.assertNotIn("path", manifest)
                    self.assertEqual(manifest["sha256"], hashlib.sha256(font).hexdigest())
                    local = second.action("font_path", sha256=manifest["sha256"])
                    self.assertEqual(Path(local["font_path"]).resolve(), (config.parent / "private.ttf").resolve())
                    self.assertIsNone(second.action("font_path", sha256="unknown")["font_path"])
                    data = bytearray()
                    while len(data) < manifest["bytes"]:
                        reply = second.action("font_asset", sha256=manifest["sha256"], offset=len(data), max_bytes=512 * 1024)
                        asset = reply["font_asset"]
                        self.assertEqual(asset["offset"], len(data))
                        self.assertEqual(len(base64.b64decode(asset["data"])), min(512 * 1024, len(font) - len(data)))
                        data.extend(base64.b64decode(asset["data"]))
                    self.assertEqual(data, font)
                    self.assertEqual(second.action("font_asset", sha256="../private.ttf")["type"], "error")
                    self.assertEqual(second.action("font_asset", sha256=manifest["sha256"], offset=len(font))["type"], "error")
                    self.assertEqual(first.action("resize_pixels", identifier, width=803, height=503)["type"], "ack")
                    small = first.sync()["panes"][0]
                    self.assertEqual(small["columns"], 803 // small["font_metrics"]["width"])
                    self.assertEqual(small["rows"], 503 // small["font_metrics"]["height"])
                    self.assertEqual(second.action("font_size", identifier, size=32)["type"], "ack")
                    large = first.sync()["panes"][0]
                    self.assertLess(large["columns"], small["columns"])
                    self.assertLess(large["rows"], small["rows"])
                    self.assertEqual(large["pid"], pid)
                    self.assertEqual(second.sync()["panes"][0]["columns"], large["columns"])
                    marker = f'FONT_PTY_{large["rows"]} {large["columns"]}_END'
                    if os.name == "nt":
                        python = sys._base_executable.replace("'", "''")
                        command = f"& '{python}' -c 'import os; s=os.get_terminal_size(); print(\"FONT_PTY_%d %d_END\" % (s.lines,s.columns))'\r"
                    else:
                        command = "printf 'FONT_PTY_%s_END\\n' \"$(stty size)\"\n"
                    first.action("text", identifier, text=command)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        first.send(dict(type="history", session=identifier))
                        text = first.until(lambda m: m.get("type") == "history")["text"]
                        if marker in text:
                            break
                        time.sleep(.02)
                    self.assertIn(marker, text)
                    first.action("font_size", identifier, size=20)
                    restored = first.sync()["panes"][0]
                    self.assertEqual((restored["columns"], restored["rows"]), (small["columns"], small["rows"]))
                    first.action("font_size", identifier, size=32, remember=False)
                    created = first.action("create", identifier)["created"]
                    panes = {p["id"]: p for p in first.sync()["panes"]}
                    self.assertEqual(panes[identifier]["font_size"], 32)
                    self.assertEqual(panes[created]["font_size"], 20, "Session restore must not change the most recent explicit choice")
                finally:
                    first.socket.close()
                    second.socket.close()


if __name__ == "__main__":
    unittest.main()
