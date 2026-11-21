# /// script
# dependencies = ["websocket-client"]
# ///
"""Real server config owns the filetree: bundled by default, or a custom Neovim command."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from test_session_transfer import Peer

runtime = ROOT / "dist/filetree"
manifest = json.loads((runtime / "manifest.json").read_text())
# Run tools/build_filetree_runtime.py first. Its Neovim also serves as the
# "custom" Neovim here, so this test needs no Neovim installation.
nvim = str(runtime / manifest["nvim"])


def remote(address, expression):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = subprocess.run([nvim, "--clean", "--headless", "--server", address, "--remote-expr", expression],
                                capture_output=True, text=True, timeout=8)
        if result.returncode == 0:
            return result.stdout.strip()
        time.sleep(.1)
    raise AssertionError(f"Neovim RPC failed: {expression}")


for mode in ("bundled", "custom", "missing"):
    with tempfile.TemporaryDirectory(prefix="gft-filetree-config-", dir="/tmp" if os.name != "nt" else None) as folder:
        root = Path(folder)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_",))}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        config = root / "config/graffitty"
        config.mkdir(parents=True)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        profile = root / "server-chromium-profile"
        init = root / "config/nvim-config-e2e/init.lua"
        init.parent.mkdir()
        init.write_text("vim.opt.swapfile=false\nvim.g.graffitty_custom_config = 1\n")
        settings = ""
        if mode != "bundled":
            executable = nvim if mode == "custom" else str(root / "missing-neovim")
            settings = ("[filetree]\ncommand = " + json.dumps([executable, "-u", str(init)])
                        + '\n[filetree.environment]\nNVIM_APPNAME = "nvim-config-e2e"\n')
        (config / "server.toml").write_text(settings + "[chromium]\nprofile = " + json.dumps(str(profile))
                                            + f"\n[remote]\nport = {port}\n")
        with PrivateServer(env, root, "/bin/sh") as server:
            peer = Peer(json.loads(server.descriptor.read_text())["local"], new=True)
            try:
                pane = peer.topology["panes"][0]["id"]
                before = len(peer.sync()["panes"])
                # Clients cannot choose the command; unknown parameters are ignored.
                reply = peer.action("rpc", pane, method="filetree.toggle", params={
                    "command": ["/missing/client-choice"], "environment": {"NVIM_APPNAME": "client-choice"}})
                if mode == "missing":
                    message = reply["error"]["message"]
                    for expected in ("filetree command", "server.toml", "[filetree] command", "bundled filetree", executable):
                        assert expected in message, message
                    assert len(peer.sync()["panes"]) == before
                    print(f"{mode} PASS", flush=True)
                    continue
                assert "error" not in reply and "pane" in reply["result"], reply
                address = reply["result"]["address"]
                argv = json.loads(remote(address, "json_encode(v:argv)"))
                if mode == "bundled":
                    assert remote(address, "$NVIM_APPNAME") == "graffitty-filetree"
                    assert Path(argv[argv.index("-u") + 1]).resolve() == (runtime / "init.lua").resolve(), argv
                    assert remote(address, "get(g:, 'graffitty_custom_config', 0)") == "0"
                else:
                    # The user's command and environment, plus only the integration options.
                    assert remote(address, "$NVIM_APPNAME") == "nvim-config-e2e"
                    assert argv[argv.index("-u") + 1] == str(init), argv
                    assert remote(address, "get(g:, 'graffitty_custom_config', 0)") == "1"
                    assert "--listen" in argv and argv.index("--listen") < argv.index("-u"), argv
                    assert not (Path(address).parent / "nvim").exists(), "Custom commands get no bundled sandbox"
                topology = peer.sync()
                assert len(topology["panes"]) == before + 1
                assert next(p for p in topology["panes"] if p["id"] == pane)["filetree_open"]
                assert "localization" not in topology
                if mode == "bundled":
                    chromium = peer.action("rpc", pane, method="chromium.create", params={"url": "about:blank"})
                    assert chromium["result"]["profile"] == str(profile), chromium
                    assert not chromium["result"]["temporary_profile"]
                    listener = peer.action("remote_access", enabled=True)
                    assert listener["result"]["url"] == f"ws://127.0.0.1:{port}", listener
                    peer.action("remote_access", enabled=False)
                closed = peer.action("rpc", pane, method="filetree.toggle", params={})
                assert "closed" in closed["result"], closed
                assert len(peer.sync()["panes"]) == before
                assert not next(p for p in peer.topology["panes"] if p["id"] == pane)["filetree_open"]
            finally:
                peer.socket.close()
        print(f"{mode} PASS", flush=True)
print("FILETREE_SERVER_CONFIG_PASS")
