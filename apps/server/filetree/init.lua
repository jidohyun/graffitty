-- Bundled Graffitty filetree config. The server starts the bundled Neovim
-- with `-u` pointing here, inside the read-only runtime that ships with
-- Graffitty.
--
-- A custom [filetree] command can start from a copy of this file; see
-- docs/customize/configuration.md#filetree.
vim.opt.laststatus = 0
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.ruler = false
vim.opt.showtabline = 0
vim.opt.cmdheight = 0
vim.opt.fillchars = { eob = " " }
vim.opt.termguicolors = true

-- Hermetic paths: only the bundled Neovim's own runtime (including its
-- Treesitter parsers) and the plugins shipped next to this file.
--
-- No shada, swap or undo files; writable stdpaths are the pane's private
-- temporary directory, which the server deletes with the pane.
--
-- Replace this block and the bundled plugin setup when supplying your own plugins.
local runtime = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local prefix = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.env.VIMRUNTIME))))
local builtin = vim.tbl_filter(function(path)
  path = vim.fs.normalize(path)
  return path == prefix or vim.startswith(path, prefix .. "/")
end, vim.opt.runtimepath:get())
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1
vim.opt.runtimepath = builtin
vim.opt.packpath = builtin
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false
vim.opt.undofile = false

-- Point vim.pack at its preinstalled directories and lockfile for registration.
-- Restore the pane's stdpaths before sourcing plugins or starting child commands.
local function register_plugins()
  local site = vim.fs.joinpath(vim.fn.stdpath("data"), "site")
  local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
  local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), "\n"))
  local specs = {}
  local directory = vim.fs.joinpath(site, "pack", "core", "opt")
  for name, kind in vim.fs.dir(directory) do
    assert(kind == "directory" and lock.plugins[name], "Unexpected bundled Neovim package: " .. name)
  end
  for _, name in ipairs({ "tokyonight.nvim", "nvim-web-devicons", "fyler.nvim", "nvim-scrollbar" }) do
    local entry = assert(lock.plugins[name], "Missing bundled Neovim lock entry: " .. name)
    local package = vim.uv.fs_lstat(vim.fs.joinpath(directory, name))
    assert(package and package.type == "directory", "Missing bundled Neovim package: " .. name)
    assert(type(entry.rev) == "string" and type(entry.src) == "string"
      and entry.version == "'" .. entry.rev .. "'", "Invalid bundled Neovim lock entry: " .. name)
    specs[#specs + 1] = { name = name, src = entry.src, version = entry.rev }
  end
  assert(vim.tbl_count(lock.plugins) == #specs, "Unexpected bundled Neovim lock entries")
  vim.opt.packpath:append(site)
  vim.pack.add(specs, { load = false })
end

do
  local appname, data_home, config_home = vim.env.NVIM_APPNAME, vim.env.XDG_DATA_HOME, vim.env.XDG_CONFIG_HOME
  vim.env.NVIM_APPNAME = "packages"
  vim.env.XDG_DATA_HOME = runtime
  vim.env.XDG_CONFIG_HOME = runtime
  local ok, err = pcall(register_plugins)
  vim.env.NVIM_APPNAME = appname
  vim.env.XDG_DATA_HOME = data_home
  vim.env.XDG_CONFIG_HOME = config_home
  if not ok then error(err) end
end
require("tokyonight").setup({ transparent = true })
vim.cmd.colorscheme("tokyonight-night")
require("nvim-web-devicons").setup({ default = true })

if not vim.env.GRAFFITTY_FILETREE_STATE then return end
local send = require("graffitty.send")
local function rpc(method, params)
  local output = vim.fn.system({ vim.env.GRAFFITTY_BIN or "gft", "rpc", method,
    "--params", vim.json.encode(params) })
  local ok, response = pcall(vim.json.decode, output)
  if vim.v.shell_error ~= 0 or not ok or type(response) ~= "table" or response.error then
    local message = ok and type(response) == "table" and response.error and response.error.message or output
    vim.notify(tostring(message), vim.log.levels.ERROR, { title = "Graffitty filetree" })
    return nil
  end
  return response.result or response
end
local function selected(instance)
  return require("fyler.finder").parse_cursor_line(instance)
end
local function open(instance)
  local entry = selected(instance)
  if not entry then return end
  if entry.type == "directory" then instance:select({})
  else
    local result = rpc("filetree.open_file", { path = entry.path })
    if result and result.address and not result.created then
      local channel = vim.fn.sockconnect("pipe", result.address, { rpc = true })
      if channel > 0 then
        pcall(vim.rpcrequest, channel, "nvim_exec_lua", "vim.cmd.edit(vim.fn.fnameescape(...))", { entry.path })
        vim.fn.chanclose(channel)
      end
    end
  end
end
local mappings = {
  ["-"] = { action = function() send.send_to_pane() end },
  ["_"] = { action = function() send.send_to_pane({ add_newline = false }) end },
  ["U"] = { action = "visit", args = { parent = true } },
  ["<CR>"] = { action = open },
  ["<2-LeftMouse>"] = { action = open },
  ["cd"] = { action = function(instance)
    local entry = selected(instance)
    if entry then
      local path = entry.type == "directory" and entry.path or vim.fn.fnamemodify(entry.path, ":h")
      send.send_to_pane({ content = "cd -- " .. vim.fn.shellescape(path) })
    end
  end },
}
require("fyler").setup({
  kind = "replace", follow_current_file = false, use_as_default_explorer = false,
  integrations = { icon = "nvim_web_devicons" },
  extensions = { git = { enabled = true }, watcher = { enabled = true } },
  win_opts = { cursorline = true, signcolumn = "no", wrap = false },
  mappings = { n = mappings }, kind_presets = { replace = { mappings = { n = mappings } } },
})

-- Scrollbar. Fyler is unwrapped, so a scrollbar over a normal window could
-- cover long filenames. Instead the tree floats over a scratch split and leaves
-- the pane's rightmost column free: nvim-scrollbar draws a thin, draggable
-- thumb there and never over a name.
require("scrollbar").setup({
  scrollbar = {
    visibility = "active", preset = "minimal", mouse = true, hide_on_cursor = false,
    floats = { when = function(context) return context.filetype == "fyler_finder" end },
    placement = { anchor = "NE", col = 1 },
    thumb = { text = "▕", blend = 0, highlight = { fg = "#7495c9" } },
  },
})
local backing
local function frame(win)
  vim.api.nvim_win_set_config(win, { relative = "editor", row = 0, col = 0,
    width = math.max(1, vim.o.columns - 1), height = math.max(1, vim.o.lines - vim.o.cmdheight),
    border = { "", "", "", " ", "", "", "", "" } })
end
local function navigate(direction)
  -- graffitty.nvim passes keys through floating windows; ask it from the
  -- split beneath, the editor's only tiled window.
  vim.api.nvim_win_call(backing, function() require("graffitty.navigator").move_to(direction) end)
end
local function float_tree(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if not (backing and vim.api.nvim_win_is_valid(backing)) then
    backing = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "below", win = win })
  end
  -- Keep the tree's own background rather than the theme's float colours.
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:Normal"
  frame(win)
  -- Only where Graffitty navigation is on: its global maps exist then.
  local buffer = vim.api.nvim_win_get_buf(win)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    local key, direction = map.lhs:match("^<C%-(%a)>$"), nil
    direction = key and ({ h = "left", j = "down", k = "up", l = "right" })[key:lower()]
    if direction and map.desc == "Graffitty navigation" then
      vim.keymap.set("n", map.lhs, function() navigate(direction) end,
        { buffer = buffer, silent = true, desc = "Graffitty navigation" })
    end
  end
end
local function trees()
  return vim.tbl_filter(function(win)
    return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "fyler_finder"
  end, vim.api.nvim_list_wins())
end
vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, { callback = function()
  vim.schedule(function() for _, win in ipairs(trees()) do float_tree(win) end end)
end })
vim.api.nvim_create_autocmd("VimResized", { callback = function()
  for _, win in ipairs(trees()) do frame(win) end
end })
-- Closing the tree closes the pane, as it did before it floated.
vim.api.nvim_create_autocmd("WinClosed", { callback = function(args)
  local closed = tonumber(args.match)
  if closed == backing then return end
  vim.schedule(function()
    if #trees() == 0 and backing and vim.api.nvim_win_is_valid(backing) then pcall(vim.cmd.quitall) end
  end)
end })

local state_file = assert(vim.env.GRAFFITTY_FILETREE_STATE, "Missing filetree state")
local pending, current, root
local function within(path, directory)
  local prefix = directory == "/" and "/" or directory .. "/"
  return path == directory or path:sub(1, #prefix) == prefix
end
local function follow()
  if not pending or pending == current then return end
  local finder = require("fyler.finder")
  local instance = finder.instance_get_or_nil()
  -- A shell navigation must not discard filesystem edits waiting for :write.
  if instance and vim.bo[instance.buf_id].modified then return end
  local cwd = pending
  if vim.fn.isdirectory(cwd) ~= 1 then return end
  if not root or not within(cwd, root) then root = vim.fs.root(cwd, ".git") or cwd end
  if not instance then
    require("fyler").open({ root_path = root, kind = "replace" })
    instance = finder.instance_get_or_nil()
  elseif root ~= instance.state.pseudo_root_path then
    instance:visit({ path = root })
  end
  if not instance then return end
  if current and current ~= cwd and within(current, cwd) then
    local prefix = cwd == "/" and "/" or cwd .. "/"
    local first = current:sub(#prefix + 1):match("^[^/]+")
    if first then
      instance.state:toggle(prefix .. first, false)
      -- Fyler's follow(root) returns without refreshing an initialized tree.
      -- Redraw the collapsed branch even when the owner returns to the root.
      instance:refresh({ force = true, recursive = true })
    end
  end
  -- Fyler resolves its follow() existence check relative to its root.
  -- Keep that cwd while selecting the owner's directory inside the tree.
  vim.cmd.tcd(vim.fn.fnameescape(root))
  instance:follow({ target_path = cwd, force = true })
  current = cwd
  vim.g.graffitty_filetree_cwd = cwd
end
local function read_state()
  local file = io.open(state_file, "rb")
  if not file then return end
  local bytes = file:read("*a")
  file:close()
  local ok, state = pcall(vim.json.decode, bytes)
  -- Fyler and vim.fs use forward slashes, including on Windows. Normalize the
  -- native shell path before comparing ancestors or collapsing a branch.
  if ok and type(state.cwd) == "string" then pending = vim.fs.normalize(state.cwd); follow() end
end
local watcher = vim.uv.new_fs_event()
local ok, err = watcher:start(vim.fn.fnamemodify(state_file, ":h"), {}, vim.schedule_wrap(function(_, name)
  if not name or name == vim.fn.fnamemodify(state_file, ":t") then read_state() end
end))
if not ok then
  -- Linux refuses another watch once the user's inotify limit is used up,
  -- which file indexers and editors routinely do. Poll the file instead.
  watcher:close()
  watcher = vim.uv.new_fs_poll()
  ok, err = watcher:start(state_file, 500, vim.schedule_wrap(read_state))
end
if not ok then error("Could not watch filetree cwd: " .. tostring(err)) end
vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost", "InsertLeave" }, { callback = function() vim.schedule(follow) end })
vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() watcher:stop(); watcher:close() end })
if vim.v.vim_did_enter == 1 then vim.schedule(read_state)
else vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.schedule(read_state) end }) end
