"""The bundled filetree runtime reads only itself and writes only its pane sandbox."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "dist/filetree"
MANIFEST = json.loads((RUNTIME / "manifest.json").read_text()) if (RUNTIME / "manifest.json").is_file() else {}
NVIM = RUNTIME / MANIFEST.get("nvim", "nvim/bin/nvim")
VIMRUNTIME = RUNTIME / MANIFEST.get("vimruntime", "nvim/share/nvim/runtime")


@unittest.skipUnless(MANIFEST, "Run tools/build_filetree_runtime.py first")
class FiletreeConfig(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="graffitty-config-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        home = self.root / "home"
        self.env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home),
                    "TMPDIR": str(self.root / "tmp"), "LOCALAPPDATA": str(home / "AppData/Local"),
                    # A user environment that would load foreign config if honored.
                    "VIMINIT": "let g:graffitty_leaked = 'VIMINIT'",
                    "VIMRUNTIME": str(self.root / "wrong-runtime")}
        (self.root / "tmp").mkdir()

    def sandboxed(self):
        """The exact flags and environment filetree.rs uses for the bundled tree."""
        sandbox = self.root / "pane/nvim"
        sandbox.mkdir(parents=True)
        env = dict(self.env, NVIM_APPNAME="graffitty-filetree", VIMRUNTIME=str(VIMRUNTIME),
                   XDG_DATA_HOME=str(sandbox / "data"), XDG_STATE_HOME=str(sandbox / "state"),
                   XDG_CACHE_HOME=str(sandbox / "cache"), NVIM_LOG_FILE=str(sandbox / "nvim.log"))
        return sandbox, env, [str(NVIM), "--headless", "-u", str(RUNTIME / "init.lua"), "-i", "NONE", "-n"]

    def test_user_config_and_plugins_are_never_loaded(self):
        home = Path(self.env["HOME"])
        leak = "vim.g.graffitty_leaked = vim.fn.expand('<sfile>')\n"
        for path in (".config/nvim/init.lua", ".config/graffitty-filetree/init.lua",
                     ".local/share/nvim/site/plugin/leak.lua",
                     ".local/share/graffitty-filetree/site/plugin/leak.lua",
                     ".local/share/nvim/site/pack/user/start/leak/plugin/leak.lua"):
            (home / path).parent.mkdir(parents=True, exist_ok=True)
            (home / path).write_text(leak)
        sandbox, env, command = self.sandboxed()
        # The bundle must register its packages with no Git executable or network fetch.
        env["PATH"] = str(self.root / "empty-path")
        env["XDG_CONFIG_HOME"] = str(home / ".config")
        probe = ("lua io.stdout:write(vim.json.encode({leaked = vim.g.graffitty_leaked or false,"
                 " colors = vim.g.colors_name, fyler = pcall(require, 'fyler'),"
                 " runtime = vim.env.VIMRUNTIME, rtp = vim.opt.runtimepath:get(),"
                 " packages = vim.pack.get(nil, {info = false}),"
                 " config_home = vim.env.XDG_CONFIG_HOME, data_home = vim.env.XDG_DATA_HOME,"
                 " appname = vim.env.NVIM_APPNAME}))")
        result = subprocess.run([*command, "+" + probe, "+qa!"], env=env, capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        state = json.loads(result.stdout)
        self.assertFalse(state["leaked"])
        self.assertTrue(state["fyler"])
        self.assertEqual(state["colors"], "tokyonight-night")
        self.assertEqual(Path(state["runtime"]), VIMRUNTIME)
        self.assertEqual(Path(state["config_home"]), home / ".config")
        self.assertEqual(Path(state["data_home"]), sandbox / "data")
        self.assertEqual(state["appname"], "graffitty-filetree")
        self.assertEqual({p["spec"]["name"]: p["rev"] for p in state["packages"] if p["active"]},
                         MANIFEST["plugins"])
        for path in state["rtp"]:
            self.assertTrue(Path(path).resolve().is_relative_to(RUNTIME.resolve()), path)

    def test_every_write_stays_in_the_pane_sandbox(self):
        sandbox, env, command = self.sandboxed()
        edited = self.root / "work/edited.txt"
        edited.parent.mkdir()
        before = {p for p in self.root.rglob("*")}
        script = "edit " + str(edited) + " | call setline(1, 'x') | write | lua vim.fn.tempname()"
        result = subprocess.run([*command, "+" + script, "+qa!"], env=env, capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        created = {p for p in self.root.rglob("*")} - before
        outside = [str(p) for p in created if not p.is_relative_to(sandbox) and p != edited
                   # Neovim's per-user temp parent; its per-process directory is removed on exit.
                   and not (p.parent == self.root / "tmp" and p.name.startswith("nvim.") and not any(p.iterdir()))]
        self.assertEqual(outside, [])
        self.assertFalse((Path(self.env["HOME"])).exists() and any(Path(self.env["HOME"]).rglob("*")))

    def test_saved_root_applies_once_with_existing_config_and_titles_follow_navigation(self):
        saved = Path(self.env["HOME"]) / "saved root %"
        moved = self.root / "home-sibling"
        saved.mkdir(parents=True)
        moved.mkdir()
        self.env["GRAFFITTY_FILETREE_ROOT"] = str(saved)
        script = self.root / "root-test.lua"
        script.write_text(
            "local buffer = vim.api.nvim_get_current_buf()\n"
            "local visits = 0\n"
            "local instance = { visit = function(_, args) visits = visits + 1; "
            "vim.api.nvim_buf_set_name(buffer, 'fyler-file://' .. args.path) end }\n"
            "package.loaded['fyler.finder'] = { instance_get_or_nil = function() return instance end }\n"
            + f"dofile({json.dumps(str(ROOT / 'apps/server/filetree/title.lua'))})\n"
            + f"vim.api.nvim_buf_set_name(buffer, 'fyler-file://' .. {json.dumps(str(self.root))})\n"
            "assert(vim.wait(1000, function() return visits == 1 end))\n"
            + f"local saved = {json.dumps(str(saved))}\n"
            "assert(vim.wait(1000, function() return vim.o.titlestring == '~/saved root %%' end))\n"
            "vim.api.nvim_buf_set_name(buffer, 'fyler-file://' .. vim.env.HOME)\n"
            "assert(vim.wait(1000, function() return vim.o.titlestring == '~' end))\n"
            + f"local moved = {json.dumps(str(moved))}\n"
            "vim.api.nvim_buf_set_name(buffer, 'fyler-file://' .. moved)\n"
            "assert(vim.wait(1000, function() return vim.o.titlestring == moved end))\n"
            "assert(visits == 1)\nvim.cmd('qa!')\n"
        )
        result = subprocess.run([str(NVIM), "--headless", "-u", "NONE", "-i", "NONE", "-l", str(script)],
                                env=dict(self.env, VIMRUNTIME=str(VIMRUNTIME)), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)



if __name__ == "__main__":
    unittest.main()
