local M = {}
function M.setup(opts)
  opts = opts or {}
  require("graffitty.send").setup(opts.send or {})
  if opts.navigator ~= false then require("graffitty.navigator").setup(opts.navigator or {}) end
  if opts.effects then require("graffitty.effects").setup(opts.effects) end
end
return M
