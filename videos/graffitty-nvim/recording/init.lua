-- Demo Neovim for the graffitty.nvim README video. It uses the README's
-- mappings and recommended Fyler settings; record.py installs the plugins
-- before filming, so nothing downloads on camera.
vim.opt.number = true
vim.opt.cursorline = true
vim.opt.termguicolors = true
vim.opt.mouse = "a"
vim.opt.swapfile = false
vim.opt.shortmess:append("I")

local lazy = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazy) then
  local output = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazy })
  if vim.v.shell_error ~= 0 then error(output) end
end
vim.opt.rtp:prepend(lazy)

local function send(opts)
  return function()
    require("graffitty.send").send_to_pane(opts)
    -- (Optional) exit visual mode after sending
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
  end
end

require("lazy").setup({
  { "folke/tokyonight.nvim", lazy = false, priority = 1000,
    config = function()
      -- Neovim panes keep the terminal background, like the shells beside them.
      require("tokyonight").setup({ transparent = true })
      vim.cmd.colorscheme("tokyonight-night")
    end },
  { "nvim-tree/nvim-web-devicons", opts = { default = true } },
  { "FylerOrg/fyler.nvim", commit = "70e1202434a21b45649dd59ec82dc3330f79125e",
    opts = {
      integrations = { icon = "nvim_web_devicons" },
      mappings = {
        n = {
          -- Recommended in the graffitty.nvim README: free `-` for sending.
          ["-"] = { disabled = true },
          ["U"] = { action = "visit", args = { parent = true } },
          -- Mouse users expand folders by double-clicking, as in the demo.
          ["<2-LeftMouse>"] = { action = "select" },
        },
      },
    } },
  {
    -- The README's spec, pinned so every take records the same plugin.
    "graffitty/graffitty.nvim",
    commit = "ee3fc34ee780b2a6d222a807cd6257fcedfd4de4",
    lazy = false,
    opts = {},
    keys = {
      { "<C-h>", function() require("graffitty.navigator").move_left() end, desc = "Navigate left" },
      { "<C-j>", function() require("graffitty.navigator").move_down() end, desc = "Navigate down" },
      { "<C-k>", function() require("graffitty.navigator").move_up() end, desc = "Navigate up" },
      { "<C-l>", function() require("graffitty.navigator").move_right() end, desc = "Navigate right" },
      { "-", send(), mode = { "n", "x" }, desc = "Send to Graffitty pane" },
      { "_", send({ add_newline = false }), mode = { "n", "x" }, desc = "Send to Graffitty pane (plain)" },
      { "<space>-", send({ count_is_uid = true }), mode = { "n", "x" }, desc = "Send to Graffitty pane w/ pane uid" },
      { "<space>_", send({ count_is_uid = true, add_newline = false }), mode = { "n", "x" },
        desc = "Send to Graffitty pane w/ pane uid (plain)" },
      {
        "<C-_>",
        function()
          require("graffitty.send").save_to_clipboard()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Save to clipboard",
      },
    },
  },
}, {
  checker = { enabled = false },
  change_detection = { notify = false },
  install = { colorscheme = { "tokyonight-night" } },
  rocks = { enabled = false },
})
