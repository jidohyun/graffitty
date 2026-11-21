-- Same preview plugin and chromium integration as the user's Neovim config.
local plugins = vim.env.DEMO_RUNTIME .. "/plugins/"
vim.opt.rtp:prepend(plugins .. "live-server.nvim")
vim.opt.rtp:prepend(plugins .. "markdown-preview.nvim")
vim.opt.number = true
vim.opt.mouse = "a"
vim.opt.swapfile = false
vim.opt.scrolloff = 8
vim.cmd.syntax("on")
require("markdown_preview").setup({
  -- A separate server keeps the recording independent of an existing preview.
  instance_mode = "multi", port = 0, open_browser = true, debounce_ms = 300,
  browser = { vim.env.GRAFFITTY_BIN, "chromium", "new", "--url" },
})
