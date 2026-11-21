vim.opt.rtp:prepend(assert(vim.env.NAVIGATION_NVIM_PLUGIN))
require("graffitty").setup({})
local nav = require("graffitty.navigator")
for key, move in pairs({ h = nav.move_left, j = nav.move_down, k = nav.move_up, l = nav.move_right }) do
  vim.keymap.set("n", "<C-" .. key .. ">", move)
end
vim.o.splitright = true
vim.o.splitbelow = true
vim.cmd.vsplit()
