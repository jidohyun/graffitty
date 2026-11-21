-- Run from this plugin directory: nvim --clean --headless -l tests/effects.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local effects = require("graffitty.effects")
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

vim.env.TMUX = nil
local written = {}
effects.write = function(sequence) table.insert(written, sequence) end
effects.setup({ enabled = true })

eq(effects.encode("hold", "md", { off = { "sparks", "camera" }, on = "cursor_trail", ["until"] = "pane" }),
  "\27]4723;effects;hold=md;off=sparks,camera;on=cursor_trail;until=pane\7")
eq(effects.encode("hold", "md", { off = "sparks, camera" }), "\27]4723;effects;hold=md;off=sparks,camera\7")
eq(effects.encode("release", "md"), "\27]4723;effects;release=md\7")
eq(effects.encode("release"), "\27]4723;effects;release\7")
eq(effects.encode("hold", "bad id", { off = "sparks" }), nil)
eq(effects.encode("hold", "md", {}), nil)
eq(effects.encode("hold", "md", { off = "sparks", ["until"] = "forever" }), nil)

vim.env.TMUX = "/tmp/tmux-501/default,1,0"
eq(effects.encode("release"), "\27Ptmux;\27\27]4723;effects;release\7\27\\")
vim.env.TMUX = nil

assert(effects.hold("normal", { off = "typing" }))
eq(written[#written], "\27]4723;effects;hold=normal;off=typing\7")
assert(effects.release("normal"))
eq(written[#written], "\27]4723;effects;release=normal\7")

-- watch: hold while the condition holds, release once when it stops.
local count = #written
vim.bo.filetype = "text"
effects.watch("md", { "FileType" }, function() return vim.bo.filetype == "markdown" end, { off = "sparks" })
eq(#written, count)
vim.bo.filetype = "markdown"
vim.wait(50, function() return #written > count end)
eq(written[#written], "\27]4723;effects;hold=md;off=sparks\7")
vim.bo.filetype = "markdown"
vim.wait(20)
eq(#written, count + 1)
vim.bo.filetype = "lua"
vim.wait(50, function() return #written > count + 1 end)
eq(written[#written], "\27]4723;effects;release=md\7")

-- Leaving Neovim releases what this module placed.
effects.hold("sticky", { off = "tab_switch", ["until"] = "clear" })
count = #written
vim.api.nvim_exec_autocmds("VimLeavePre", {})
eq(written[#written], "\27]4723;effects;release=sticky\7")
eq(#written, count + 1)

-- Outside Graffitty nothing is written.
effects.setup({ enabled = false })
count = #written
assert(not effects.hold("x", { off = "sparks" }))
eq(#written, count)
print("EFFECTS_PASS")
