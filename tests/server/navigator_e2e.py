#!/usr/bin/env python3
"""Real editor-owned keys, native tmux routing, and short-lived gft edge calls."""
import argparse
import json
import os
import select
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from local_media_e2e import LocalClient, PrivateServer

ROOT = Path(__file__).resolve().parents[2]


class Frontend(LocalClient):
    """Acknowledge actual CLI presentation requests and record their source."""
    def __init__(self, descriptor):
        self.moves = []
        super().__init__(descriptor)
        assert self.action("frontend_register", generation=1)["owner"]

    def receive(self):
        start = len(self.messages)
        super().receive()
        for message in self.messages[start:]:
            if message.get("type") == "frontend_request":
                assert message["method"] == "navigator.focus", message
                self.moves.append(message)
                self.send(dict(type="frontend_reply", ticket=message["ticket"],
                               response={"result": {"outcome": "moved"}}))

    def pump(self):
        if select.select([self.socket], [], [], .02)[0]:
            self.receive()

    def eventually(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while not predicate():
            assert time.monotonic() < deadline, "Navigation did not complete"
            self.pump()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tpm", type=Path, help="TPM checkout to test real plugin installation and loading")
    parser.add_argument("--profile", type=Path, default=ROOT / "tests/containers/navigation",
                        help="Checked-in tmux.conf and Neovim init.lua fixture")
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="gft-nav-", dir=os.environ.get("GRAFFITTY_E2E_ARTIFACTS", "/tmp")))
    print("Evidence:", directory, flush=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GRAFFITTY_", "CODEX_")) and k not in ("TMUX", "TMUX_PANE")}
    (directory / "home").mkdir()
    env["HOME"] = str(directory / "home")
    for key in ("CONFIG", "STATE", "DATA", "CACHE"):
        env["XDG_" + key + "_HOME"] = str(directory / key.lower())
    env["PATH"] = str(ROOT / "target/debug") + os.pathsep + env["PATH"]
    env["NAVIGATION_NVIM_PLUGIN"] = str(ROOT / "integrations/graffitty.nvim")
    address = directory / "nvim.sock"
    init = directory / "init.lua"
    shutil.copy2(args.profile / "init.lua", init)

    env["GRAFFITTY_SERVER__NAVIGATOR__ENABLED"] = "true"
    with PrivateServer(env, directory, "/bin/zsh") as owner:
        client = Frontend(json.loads(owner.descriptor.read_text()))
        pane = int(client.topology["panes"][0]["id"])

        def rpc(method, params=None, source=pane):
            if method == "navigator.input" and params is None:
                params = {"key": "ctrl+h", "context": {"origin": f"%{source}", "rects": {f"%{source}": [0, 0, 100, 100]}}}
            return client.action("rpc", source, method=method, params=params or {})

        def lua(code):
            process = subprocess.Popen(["nvim", "--server", str(address), "--remote-expr", "luaeval(" + json.dumps(code) + ")"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
            deadline = time.monotonic() + 8
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    process.kill()
                    process.communicate()
                    (directory / "nvim-timeout.json").write_text(json.dumps(rpc("terminal.get_text"), indent=2))
                    raise AssertionError("Neovim RPC timed out")
                client.pump()
            stdout, stderr = process.communicate()
            assert process.returncode == 0, (stdout, stderr)
            return stdout.strip()

        def press(key, source=pane):
            client.action("text", source, text=key)

        def edge(key, source=pane):
            before = len(client.moves)
            press(key, source)
            client.eventually(lambda: len(client.moves) > before)
            assert len(client.moves) == before + 1
            assert client.moves[-1]["session"] == source, client.moves[-1]
            return client.moves[-1]["params"]["direction"]

        command = f"nvim -u {shlex.quote(str(init))} --listen {shlex.quote(str(address))}\n"
        press(command)
        client.eventually(address.exists)
        client.eventually(lambda: rpc("navigator.input")["outcome"] == "pass")
        client.eventually(lambda: lua("vim.v.vim_did_enter") == "1")
        right = lua("(function() vim.cmd.wincmd('l'); return vim.api.nvim_get_current_win() end)()")
        press("\x08")
        client.eventually(lambda: lua("vim.api.nvim_get_current_win()") != right)
        assert not client.moves, "Moving inside Neovim must not invoke gft"
        assert edge("\x08") == "left"
        press("\x0c")
        client.eventually(lambda: lua("vim.api.nvim_get_current_win()") == right)
        assert edge("\x0c") == "right"
        assert lua('package.loaded["graffitty.bridge"] == nil') == "true"
        lua("(function() vim.cmd.split(); return true end)()")
        bottom = lua("vim.api.nvim_get_current_win()")
        press("\x0b")
        client.eventually(lambda: lua("vim.api.nvim_get_current_win()") != bottom)
        press("\x0a")
        client.eventually(lambda: lua("vim.api.nvim_get_current_win()") == bottom)
        before = len(client.moves)
        lua("(function() vim.cmd.startinsert(); return true end)()")
        press("x\x08")
        assert lua("vim.api.nvim_get_mode().mode") == "i"
        assert len(client.moves) == before, "Insert mode retains keys"
        lua("(function() vim.cmd.stopinsert(); return true end)()")
        press("\x1a")
        client.eventually(lambda: rpc("navigator.input")["outcome"] == "edge")
        press("fg\n")
        client.eventually(lambda: rpc("navigator.input")["outcome"] == "pass")
        lua("(function() vim.schedule(function() vim.cmd('qa!') end); return true end)()")
        client.eventually(lambda: rpc("navigator.input")["outcome"] == "edge")
        print("PASS Neovim-owned mappings, gft only at edges, insert mode, suspend/resume", flush=True)

        tree_result = rpc("filetree.toggle", {"focus": True})
        tree = int(tree_result.get("pane", tree_result.get("focus")).lstrip("%"))
        before = len(client.moves)
        deadline = time.monotonic() + 60
        while len(client.moves) == before:
            assert time.monotonic() < deadline, "Managed Fyler did not handle its keymap"
            press("\x0c", tree)
            until = time.monotonic() + .2
            while time.monotonic() < until and len(client.moves) == before:
                client.pump()
        assert client.moves[-1]["session"] == tree
        assert edge("\x08", tree) == "left"
        rpc("filetree.toggle", {}, pane)
        print("PASS managed Fyler invokes gft at its edge without registration", flush=True)

        sock = str(directory / "tmux.sock")
        def tm(*args):
            return subprocess.check_output(["tmux", "-S", sock, *args], env=env, text=True).strip()
        try:
            press(f"tmux -S {shlex.quote(sock)} -f {shlex.quote(str(args.profile / 'tmux.conf'))} new-session -s nav\n")
            client.eventually(lambda: Path(sock).exists())
            plugin = ROOT / "integrations/tmux-graffitty"
            if args.tpm:
                # TPM installs a real standalone plugin repository, without
                # fetching from the network or touching the user's tmux server.
                source = directory / "source/tmux-graffitty"
                shutil.copytree(plugin, source)
                def git(*argv):
                    subprocess.run(["git", "-C", str(source), *argv], check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                git("init", "-q")
                git("add", ".")
                git("-c", "user.name=Navigation Test", "-c", "user.email=test@example.invalid",
                    "commit", "--no-gpg-sign", "-qm", "TPM test fixture")
                plugins = directory / "plugins"
                tpm = args.tpm.resolve()
                config = directory / "home/.tmux.conf"
                config.write_text((args.profile / "tmux.conf").read_text() + "\n" +
                                  f'set-environment -g TMUX_PLUGIN_MANAGER_PATH "{plugins}/"\n'
                                  f'set -g @plugin "{source}"\n'
                                  f'run-shell "{tpm / "tpm"}"\n')
                tm("source-file", str(config))
                tm("run-shell", shlex.quote(str(tpm / "bin/install_plugins")))
                assert (plugins / "tmux-graffitty/.git").is_dir(), "TPM must clone the plugin"
                # TPM's installation output opens tmux's output/copy mode.
                if tm("display-message", "-p", "#{pane_in_mode}") != "0":
                    tm("send-keys", "-X", "cancel")
                tm("source-file", str(config))
                reload_command = ("source-file", str(config))
            else:
                reload_command = ("run-shell", shlex.quote(str(plugin / "graffitty.tmux")))
                tm(*reload_command)
            client.eventually(lambda: "select-pane -L --client-tty" in tm("list-keys", "-T", "root"))
            environment_before = tm("show-options", "-gv", "update-environment")
            tm(*reload_command)
            assert tm("show-options", "-gv", "update-environment") == environment_before, "Reload must be idempotent"
            print("PASS tmux plugin loading and reload" + (" through TPM" if args.tpm else ""), flush=True)
            client.eventually(lambda: rpc("navigator.input")["outcome"] == "pass")
            left = tm("display-message", "-p", "#{pane_id}")
            client.eventually(lambda: tm("display-message", "-p", "-t", left, "#{pane_current_command}") == "zsh")
            right_pane = tm("split-window", "-h", "-P", "-F", "#{pane_id}")
            client.eventually(lambda: tm("display-message", "-p", "-t", right_pane, "#{pane_current_command}") == "zsh")
            before = len(client.moves)
            press("\x08")
            client.eventually(lambda: tm("display-message", "-p", "#{pane_id}") == left)
            assert len(client.moves) == before, "Internal tmux movement must not invoke gft"
            assert edge("\x08") == "left"
            press("\x0c")
            client.eventually(lambda: tm("display-message", "-p", "#{pane_id}") == right_pane)
            assert edge("\x0c") == "right"
            assert tm("display-message", "-p", "#{pane_id}") == right_pane, "No wrapping"
            bottom_pane = tm("split-window", "-v", "-P", "-F", "#{pane_id}")
            client.eventually(lambda: tm("display-message", "-p", "-t", bottom_pane, "#{pane_current_command}") == "zsh")
            press("\x0b")
            client.eventually(lambda: tm("display-message", "-p", "#{pane_id}") == right_pane)
            press("\x0a")
            client.eventually(lambda: tm("display-message", "-p", "#{pane_id}") == bottom_pane)
            tm("resize-pane", "-Z")
            assert edge("\x0b") == "up"
            assert tm("display-message", "-p", "#{pane_id}:#{window_zoomed_flag}") == bottom_pane + ":1"
            tm("resize-pane", "-Z")
            tm("send-keys", "-t", bottom_pane, command.strip(), "Enter")
            client.eventually(address.exists)
            lua("(function() vim.cmd.only(); vim.cmd.vsplit(); return true end)()")
            win = lua("vim.api.nvim_get_current_win()")
            press("\x08")
            client.eventually(lambda: lua("vim.api.nvim_get_current_win()") != win)
            assert tm("display-message", "-p", "#{pane_id}") == bottom_pane
            press("\x0b")
            client.eventually(lambda: tm("display-message", "-p", "#{pane_id}") == right_pane)
            tm("select-pane", "-t", bottom_pane)
            assert edge("\x0a") == "down", "Neovim -> tmux edge -> gft"

            client.sequence += 1
            request = client.sequence
            client.send(dict(type="create", kind="pane", session=pane, request=request))
            client.until(lambda: any(m.get("request") == request for m in client.messages))
            created = next(m for m in client.messages if m.get("request") == request)
            assert created["type"] == "ack", created
            second = created["created"]
            press(f"tmux -S {shlex.quote(sock)} attach -t nav\n", second)
            client.eventually(lambda: rpc("navigator.input", source=second)["outcome"] == "pass")
            assert edge("\x0a", second) == "down", "Editor edge resolves the active tmux client"
            tm("select-pane", "-t", left)
            assert edge("\x08", second) == "left", "Shell edge targets the initiating tmux client"
            before = len(client.moves)
            tm("copy-mode")
            press("\x08", second)
            assert tm("display-message", "-p", "#{pane_in_mode}") == "1"
            assert len(client.moves) == before
            tm("send-keys", "-X", "cancel")
            print("PASS native tmux bindings, zoom, no wrap, nested Neovim, two clients, copy mode", flush=True)
        except BaseException:
            state = {"terminal": rpc("terminal.get_text"),
                     "panes": tm("list-panes", "-a", "-F", "#{pane_id} active=#{pane_active} command=#{pane_current_command} mode=#{pane_in_mode} left=#{pane_at_left} right=#{pane_at_right}"),
                     "clients": tm("list-clients", "-F", "#{client_tty} #{client_key_table}"),
                     "keys": tm("list-keys", "-T", "root"), "moves": client.moves}
            (directory / "tmux-failure.json").write_text(json.dumps(state, indent=2))
            raise
        finally:
            subprocess.run(["tmux", "-S", sock, "kill-server"], capture_output=True)
        client.close()
    print("NAVIGATOR_E2E_PASS")


if __name__ == "__main__":
    main()
