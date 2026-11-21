#!/usr/bin/env python3
"""Real owner, Zsh, bundled Fyler runtime and gft delivery; isolated config/data and processes."""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlsplit

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from local_media_e2e import LocalClient, PrivateServer


def main():
    root = Path(tempfile.mkdtemp(prefix="graffitty-filetree-e2e-"))
    print("Evidence:", root, flush=True)
    home = root / "home"
    home.mkdir()
    project = home / "project"
    child = project / "nested Ω % ' directory"
    child.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    selected = child / "file ' ; $x.txt"
    selected.write_text("file contents\n")
    second = child / "another # ' |.txt"
    second.write_text("second file\n")
    image = child / "preview Ω # %.SVG"
    image.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="80" height="60"><rect width="80" height="60" fill="blue"/></svg>')
    png = child / "preview.png"
    png.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5L8AAAAASUVORK5CYII="))
    html = child / "preview.html"
    html.write_text('<!doctype html><title>Filetree preview</title><textarea>preview selection</textarea>')
    pdf = child / "preview.pdf"
    # One genuine PDF page, with a correct cross-reference table.
    document = bytearray(b"%PDF-1.4\n")
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>"]
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(document))
        document.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(document)
    document.extend(b"xref\n0 4\n0000000000 65535 f \n")
    document.extend(b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:]))
    document.extend(f"trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    pdf.write_bytes(document)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    env["HOME"] = str(home)
    env["GODOT_CHROMIUM_AUDIT"] = "1"
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    repo = Path(__file__).resolve().parents[2]
    # The server finds the bundled runtime in dist/ (tools/build_filetree_runtime.py).
    runtime = repo / "dist/filetree"
    manifest = json.loads((runtime / "manifest.json").read_text())
    client_nvim = runtime / manifest["nvim"]
    xdg = [Path(env[f"XDG_{kind}_HOME"]) for kind in ("CONFIG", "STATE", "CACHE", "DATA")]
    with PrivateServer(env, root, "/bin/zsh") as owner:
        client = LocalClient(json.loads(owner.descriptor.read_text()))
        try:
            source = int(client.topology["panes"][0]["id"])

            def request(kind, session=source, **values):
                client.sequence += 1
                seq = client.sequence
                client.send(dict(type=kind, session=session, request=seq, **values))
                client.until(lambda: any(m.get("request") == seq for m in client.messages))
                reply = next(m for m in client.messages if m.get("request") == seq)
                assert reply["type"] == "ack", reply
                return reply

            def rpc(method, params=None, session=source):
                return request("rpc", session, method=method, params=params or {})["result"]

            def latest():
                observer = LocalClient(json.loads(owner.descriptor.read_text()))
                try: return observer.topology
                finally: observer.close()

            def state():
                return request("workspace_get")["workspace_state"]

            def edit(change):
                snapshot = state()
                tab = snapshot["active"]
                layout = snapshot["layout"]["tabs"][str(tab)]
                change(layout)
                return request("workspace_edit", expected_revision=snapshot["revision"],
                               edit={"op": "tab", "tab": tab, "layout": layout})

            def rectangle(key):
                snapshot = state()
                layout = snapshot["layout"]["tabs"][str(snapshot["active"])]
                if layout["enabled"] and not next(w for w in layout["windows"] if w["key"] == key)["stashed"]:
                    children = layout["tiles"]["children"]
                    weights = [c.get("weight") or 1 for c in children]
                    return [0, 0, weights[0] / sum(weights), 0]
                return next(p["rect"] for p in latest()["panes"] if p["id"] == int(key[1:]))

            def wait(predicate, timeout=30):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate(): return
                    time.sleep(.05)
                raise AssertionError("Timed out")

            def nvim(address, expression):
                try:
                    result = subprocess.run([str(client_nvim), "--clean", "--headless", "--server", address,
                                             "--remote-expr", expression], capture_output=True, text=True, timeout=8)
                except subprocess.TimeoutExpired:
                    # First-use plugin downloads can block startup before RPC is ready.
                    if "luaeval" in expression:
                        raise
                    return ""
                if result.returncode != 0 and "luaeval" in expression:
                    raise AssertionError(result.stderr + result.stdout)
                return result.stdout.strip() if result.returncode == 0 else ""

            # Install the real hook in the test shell and wait for a marker file.
            hook = Path(__file__).resolve().parents[2] / "apps/server/shell-integration/integration.sh"
            ready = root / "shell-ready"
            request("text", text=f"source {shlex.quote(str(hook))}; cd {shlex.quote(str(project))}; touch {shlex.quote(str(ready))}\n")
            wait(ready.exists)
            opened = rpc("filetree.toggle")
            pane = int(opened["pane"][1:])
            address = opened["address"]
            client.subscribe(pane)
            # The bundled runtime needs no download: the tree is ready immediately.
            wait(lambda: nvim(address, "get(g:, 'graffitty_filetree_cwd', '')") == str(project), 15)
            assert nvim(address, "&filetype") == "fyler_finder"
            assert nvim(address, "$NVIM_APPNAME") == "graffitty-filetree"
            sandbox = Path(address).parent / "nvim"
            assert Path(nvim(address, "v:progpath")).resolve() == client_nvim.resolve()
            argv = json.loads(nvim(address, "json_encode(v:argv)"))
            assert Path(argv[argv.index("-u") + 1]).resolve() == (runtime / "init.lua").resolve(), argv
            assert "-n" in argv and argv[argv.index("-i") + 1] == "NONE", argv
            for kind in ("data", "state", "cache"):
                assert Path(nvim(address, f"stdpath('{kind}')")).is_relative_to(sandbox), kind
            assert nvim(address, "&shadafile") == "NONE" and nvim(address, "&swapfile") == "0"
            assert nvim(address, "luaeval('require(\"fyler.config\").DATA.extensions.git.enabled and 1 or 0')") == "1"
            assert nvim(address, "get(g:, 'colors_name', '')") == "tokyonight-night"
            assert nvim(address, "luaeval('require(\"fyler.config\").DATA.integrations.icon')") == "nvim_web_devicons"
            # Fyler replaces the whole pane; no popup or split remains.
            wait(lambda: nvim(address, "luaeval('#vim.api.nvim_list_wins()')") == "1")
            assert nvim(address, "luaeval('vim.api.nvim_win_get_config(0).relative')") == ""
            assert nvim(address, "winwidth(0) == &columns && winheight(0) == &lines ? 1 : 0") == "1"
            icon = nvim(address, "luaeval('require(\"fyler.integrations.icon\").get(\"file\", \"init.lua\")')")
            assert icon and not icon.isascii(), icon
            print("Bundled sandboxed runtime, full-pane Fyler, TokyoNight, Nerd Font icons and Git status PASS", flush=True)

            # The tree must follow before the next prompt, while a job is running.
            request("text", text=f"cd {shlex.quote(str(child))}; sleep 2\n")
            wait(lambda: nvim(address, "get(g:, 'graffitty_filetree_cwd', '')") == str(child), 1.5)
            assert nvim(address, "luaeval('require(\"fyler\").getcwd()')") == str(project)
            wait(lambda: Path(nvim(address, "luaeval('(require(\"fyler.finder\").parse_cursor_line(require(\"fyler.finder\").instance_get_or_nil()) or {}).path or \"\"')")).resolve() == child.resolve(), 1.5)
            time.sleep(2)
            print("Immediate OSC cwd following and retained root PASS", flush=True)

            # Returning to the root must redraw the branch that was collapsed.
            request("text", text="cd ..\n")
            wait(lambda: nvim(address, "get(g:, 'graffitty_filetree_cwd', '')") == str(project))
            wait(lambda: selected.name not in nvim(address, "join(getline(1, '$'), '\n')"))
            request("text", text="cd ..\n")
            wait(lambda: nvim(address, "luaeval('require(\"fyler\").getcwd()')") == str(home))
            request("text", text=f"cd {shlex.quote(str(child))}\n")
            wait(lambda: nvim(address, "get(g:, 'graffitty_filetree_cwd', '')") == str(child))
            wait(lambda: selected.name in nvim(address, "join(getline(1, '$'), '\n')"))
            print("Cwd parent navigation collapses, changes root and reopens the project PASS", flush=True)

            # Send through the real Neovim plugin, gft and bracketed paste path.
            sent = root / "sent.txt"
            command = "printf '%s' " + shlex.quote(str(selected)) + " > " + shlex.quote(str(sent))
            lua = "(function() require('graffitty.send').send_to_pane({content=" + json.dumps(command, ensure_ascii=False) + "}); return 1 end)()"
            expression = "luaeval(" + "'" + lua.replace("'", "''") + "'" + ")"
            assert nvim(address, expression) == "1"
            wait(sent.exists)
            assert sent.read_text() == str(selected)
            print("graffitty.send → gft → connected Zsh PASS", flush=True)

            # Exercise Fyler's actual selected-path grabber, including quoting.
            def lua(code):
                return nvim(address, "luaeval('" + code.replace("'", "''") + "')")
            choose = "require('fyler.finder').instance_get_or_nil():follow({force=true,target_path=" + json.dumps(str(selected), ensure_ascii=False) + "})"
            lua("(function() " + choose + "; return 1 end)()")
            wait(lambda: Path(lua("require('fyler.finder').parse_cursor_line(require('fyler.finder').instance_get_or_nil()).path")).resolve() == selected.resolve())
            lua("(function() vim.cmd('normal! $h'); return 1 end)()")
            column = int(lua("vim.api.nvim_win_get_cursor(0)[2]"))
            lua("(function() vim.cmd.normal('l'); return 1 end)()")
            assert int(lua("vim.api.nvim_win_get_cursor(0)[2]")) == column + 1
            lua("(function() vim.cmd.normal('h'); return 1 end)()")
            assert int(lua("vim.api.nvim_win_get_cursor(0)[2]")) == column
            assert len(latest()["panes"]) == 2
            print("h/l move through filenames without opening another pane PASS", flush=True)
            grabbed = root / "grabbed.txt"
            request("text", text="printf '%s'")
            lua("(function() require('graffitty.send').send_to_pane({add_newline=false}); return 1 end)()")
            request("text", text=" > " + shlex.quote(str(grabbed)) + "\n")
            wait(grabbed.exists)
            assert Path(grabbed.read_text()).resolve() == selected.resolve()
            print("Fyler selected path with quotes, spaces, Unicode and shell metacharacters PASS", flush=True)

            # Opening creates a viewer above the owner, linked to the filetree.
            viewer = rpc("filetree.open_file", {"path": str(selected)}, session=pane)
            viewer_id = int(viewer["pane"][1:])
            wait(lambda: Path(nvim(viewer["address"], "expand('%:p')")).resolve() == selected.resolve())
            viewer_pid = nvim(viewer["address"], "getpid()")
            first_buffer = nvim(viewer["address"], "bufnr('%')")
            topology = latest()
            panes = {p["id"]: p for p in topology["panes"]}
            assert panes[pane]["filetree_owner"] == source
            assert panes[viewer_id]["filetree_owner"] == pane
            assert panes[pane]["builtin_title"] == "" and panes[pane]["pinned_title"] == ""
            assert Path(panes[pane]["title"]).expanduser().resolve() == Path(lua("require('fyler.finder').instance_get_or_nil().state.pseudo_root_path")).resolve()
            assert panes[viewer_id]["builtin_title"] == "File viewer" and panes[viewer_id]["pinned_title"] == ""
            assert panes[viewer_id]["rect"][1] < panes[source]["rect"][1]
            again = rpc("filetree.open_file", {"path": str(selected)}, session=pane)
            assert again["pane"] == viewer["pane"] and not again["created"]
            for path in (second, selected, second):
                choose = "require('fyler.finder').instance_get_or_nil():follow({force=true,target_path=" + json.dumps(str(path), ensure_ascii=False) + "})"
                lua("(function() " + choose + "; return 1 end)()")
                wait(lambda: Path(lua("require('fyler.finder').parse_cursor_line(require('fyler.finder').instance_get_or_nil()).path")).resolve() == path.resolve())
                lua("(function() require('fyler.config').DATA.mappings.n['<CR>'].action(require('fyler.finder').instance_get_or_nil()); return 1 end)()")
                wait(lambda: Path(nvim(viewer["address"], "expand('%:p')")).resolve() == path.resolve())
                assert nvim(viewer["address"], "getpid()") == viewer_pid
                assert {p["id"] for p in latest()["panes"]} == set(panes)
                assert nvim(viewer["address"], "tabpagenr('$')") == "1"
                assert nvim(viewer["address"], "winnr('$')") == "1"
                assert nvim(viewer["address"], "len(getbufinfo({'buflisted': 1}))") == "2"
                if path == selected:
                    assert nvim(viewer["address"], "bufnr('%')") == first_buffer
            print("File opens reuse Neovim process, pane, window and tab with two reusable buffers PASS", flush=True)
            chromium = rpc("filetree.open_file", {"path": str(image)}, session=pane)
            chromium_id = int(chromium["pane"][1:])
            assert chromium["kind"] == "chromium" and chromium["created"]

            def chromium_command(controller, action, args=None):
                ticket = rpc("chromium.command", {"chromium": chromium["pane"], "action": action, "args": args or {}}, session=controller)["ticket"]
                result = None
                deadline = time.monotonic() + 15
                while result is None and time.monotonic() < deadline:
                    result = rpc("chromium.result", {"chromium": chromium["pane"], "ticket": ticket}, session=controller)
                    time.sleep(.02)
                assert result is not None and "error" not in result, result
                return result["result"]

            chromium_state = chromium_command(pane, "chrome-state")
            def assert_embedded(value):
                assert value["nativeVisible"] is False, value
                if sys.platform == "darwin":
                    assert value["presentationAudited"], value
                    assert value["windowCount"] == (0 if value["backend"] == "alloy" else 1), value
                    for counter in ("visibleWindows", "unexpectedWindowOrders", "unexpectedKeyEvents", "unexpectedActivations"):
                        assert value[counter] == 0, (counter, value)
            assert_embedded(chromium_state)
            assert str(image) in [unquote(urlsplit(t["url"]).path) for t in chromium_state["tabs"]], chromium_state
            chromium_pid = chromium_state["pid"]
            for count, path in enumerate((png, image), start=2):
                again_chromium = rpc("filetree.open_file", {"path": str(path)}, session=pane)
                assert again_chromium["pane"] == chromium["pane"] and not again_chromium["created"]
                chromium_state = chromium_command(pane, "chrome-state")
                assert len(chromium_state["tabs"]) == count and chromium_state["pid"] == chromium_pid, chromium_state
                assert str(path) == unquote(urlsplit(next(t["url"] for t in chromium_state["tabs"] if t["selected"])).path)
                assert_embedded(chromium_state)
            again_chromium = rpc("filetree.open_file", {"path": str(html)}, session=pane)
            assert again_chromium["pane"] == chromium["pane"] and not again_chromium["created"]
            chromium_state = chromium_command(pane, "chrome-state")
            assert len(chromium_state["tabs"]) == 4 and chromium_state["pid"] == chromium_pid, chromium_state
            assert_embedded(chromium_state)
            assert str(html) in [unquote(urlsplit(t["url"]).path) for t in chromium_state["tabs"]]
            opened_pdf = rpc("filetree.open_file", {"path": str(pdf)}, session=pane)
            assert opened_pdf["pane"] == chromium["pane"] and not opened_pdf["created"]
            pdf_state = chromium_command(pane, "chrome-state")
            assert len(pdf_state["tabs"]) == 5 and pdf_state["pid"] == chromium_pid
            assert_embedded(pdf_state)
            assert str(pdf) in [unquote(urlsplit(t["url"]).path) for t in pdf_state["tabs"]]
            embedded_pdf = chromium_command(pane, "cdp", {"method":"Runtime.evaluate", "params":{
                "expression":"document.contentType === 'application/pdf' || !!document.querySelector('embed[type=\"application/pdf\"]')", "returnByValue":True}})
            assert embedded_pdf["result"]["value"], embedded_pdf
            assert len(latest()["chromiums"]) == 1 and latest()["chromiums"][0]["owner"] == pane
            nvim(viewer["address"], "luaeval('(function() vim.api.nvim_buf_set_lines(0, 0, 1, false, {\"unsaved viewer edit\"}); return 1 end)()')")
            closed = rpc("filetree.toggle", session=viewer_id)
            topology = latest()
            ids = {p["id"] for p in topology["panes"]}
            assert source in ids and pane not in ids and viewer_id in ids
            detached = next(p for p in topology["panes"] if p["id"] == viewer_id)
            assert not detached.get("filetree_owner")
            assert not Path(address).exists() and Path(viewer["address"]).exists()
            assert not sandbox.exists(), "Closing the tree deletes its writable stdpaths"
            assert nvim(viewer["address"], "getpid()") == viewer_pid
            assert nvim(viewer["address"], "&modified") == "1"
            assert nvim(viewer["address"], "getline(1)") == "unsaved viewer edit"
            assert latest()["chromiums"][0]["owner"] == chromium_id
            assert chromium_command(chromium_id, "chrome-state")["pid"] == chromium_pid
            # Explicitly close this test-owned viewer only after verifying survival.
            request("close", viewer_id)
            assert not Path(viewer["address"]).parent.exists()
            print("Filetree close detaches viewer, preserving its process and unsaved edits PASS", flush=True)
            assert closed["focus"] == f"%{source}"
            reopened = rpc("filetree.toggle", {"focus": True})
            assert reopened["focus"] == reopened["pane"]
            wait(lambda: nvim(reopened["address"], "&filetype") == "fyler_finder")
            reused_chromium = rpc("filetree.open_file", {"path": str(image)}, session=int(reopened["pane"][1:]))
            assert reused_chromium["pane"] == chromium["pane"] and not reused_chromium["created"]
            rpc("filetree.toggle")
            reopened_state = chromium_command(chromium_id, "chrome-state")
            assert len(reopened_state["tabs"]) == 6
            assert_embedded(reopened_state)
            rpc("chromium.close", {"chromium": chromium["pane"]}, session=chromium_id)
            print("Chromium previews reuse tabs, encode file URLs, detach and reconnect without replacing the process PASS", flush=True)
            print("Reopened bundled tree and toggle focus results PASS", flush=True)
            # Resize/reopen in each mode, then revisit each saved mode.
            saved = {}
            def set_mode(layout, mode):
                layout["enabled"] = mode != "floating"
                for window in layout["windows"]:
                    window["stashed"] = mode == "outside"
                    window["graph_floating"] = False

            for mode in ("tiled", "floating", "outside"):
                edit(lambda layout: set_mode(layout, mode))
                opened_size = rpc("filetree.toggle")
                key = opened_size["pane"]
                def resize(layout):
                    if mode == "tiled":
                        # The filetree is a left split around the owner.
                        children = layout["tiles"]["children"]
                        children[0]["weight"] = .27
                        children[1]["weight"] = .73
                    else:
                        window = next(w for w in layout["windows"] if w["key"] == key)
                        window["rect"][2:] = [371, 429] if mode == "floating" else [289, 513]
                edit(resize)
                saved[mode] = rectangle(key)[2:]
                rpc("filetree.toggle")
            for mode, size in saved.items():
                edit(lambda layout: set_mode(layout, mode))
                opened_size = rpc("filetree.toggle")
                actual = rectangle(opened_size["pane"])[2:]
                assert all(abs(a - b) < (0.0001 if mode == "tiled" else 1) for a, b in zip(actual, size)), (mode, size, actual)
                rpc("filetree.toggle")
            print("Distinct tiled, floating and outside-main-area sizes restored PASS", flush=True)

            # Moving the owner retains the ownership chain; owner close detaches the viewer.
            opened_move = rpc("filetree.toggle")
            moved_tree = int(opened_move["pane"][1:])
            viewer = rpc("filetree.open_file", {"path": str(selected)}, session=moved_tree)
            wait(lambda: nvim(viewer["address"], "getpid()") != "")
            viewer_pid = nvim(viewer["address"], "getpid()")
            chromium = rpc("filetree.open_file", {"path": str(html)}, session=moved_tree)
            chromium_id = int(chromium["pane"][1:])
            chromium_pid = chromium_command(moved_tree, "chrome-state")["pid"]
            moved = request("regroup", surface=f"%{source}")
            assert moved["source_empty"]
            assert all(p["tab"] == moved["tab"] for p in latest()["panes"])
            request("create")
            request("close", source)
            panes = {p["id"]: p for p in latest()["panes"]}
            assert source not in panes and moved_tree not in panes
            assert not panes[int(viewer["pane"][1:])].get("filetree_owner")
            assert nvim(viewer["address"], "getpid()") == viewer_pid
            assert chromium_command(chromium_id, "chrome-state")["pid"] == chromium_pid
            print("Ownership survives tab transfer; owner close also preserves viewer PASS", flush=True)
            # Nothing the trees or their plugins did wrote into the user's XDG
            # directories. (The file viewer is the user's own Neovim: state/nvim.)
            leaked = [str(p) for path in xdg for p in (path / "graffitty-filetree", *path.glob("*/tokyonight*"))
                      if p.exists()]
            assert not leaked, leaked
            print("No filetree state outside pane sandboxes PASS", flush=True)
            (root / "result.json").write_text(json.dumps({"status": "PASS", "opened": opened, "reopened": reopened}, indent=2))
        finally:
            client.close()
    print("FILETREE_PASS", flush=True)


if __name__ == "__main__":
    main()
