-- Reference results from Neovim for copy-mode differential tests.
-- nvim --headless --clean -l reference.lua cases.jsonl out.jsonl
local cases_path, out_path = arg[1], arg[2]
local out = assert(io.open(out_path, 'w'))
vim.o.report = 99999
for _, mode in ipairs({'n', 'x', 'o'}) do pcall(vim.keymap.del, mode, '%') end
vim.o.shortmess = 'aoOstTWIcCFSsq'
local term = function(s) return vim.api.nvim_replace_termcodes(s, true, true, true) end
for line in io.lines(cases_path) do
  local c = vim.json.decode(line)
  local old = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_buf_delete, old, { force = true })
  for k, v in pairs(c.opts or {}) do vim.o[k] = v end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, c.lines)
  local bytecol = math.max(0, vim.fn.virtcol2col(0, c.cursor[1] + 1, c.cursor[2] + 1) - 1)
  vim.api.nvim_win_set_cursor(0, { c.cursor[1] + 1, bytecol })
  vim.fn.setreg('"', ''); vim.fn.setreg('0', ''); vim.fn.setreg('/', '')
  vim.fn.setcharsearch({ char = '', forward = 1, ['until'] = 0 })
  vim.v.searchforward = 1
  local ok, err = true, nil
  for _, cmd in ipairs(c.cmds or { c.keys }) do
    local good, e = pcall(vim.api.nvim_feedkeys, term(cmd), 'mx', false)
    if not good then ok, err = false, e end
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local current = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
  pos[2] = vim.fn.strdisplaywidth(current:sub(1, pos[2]))
  local result = {
    id = c.id, cursor = { pos[1] - 1, pos[2] }, mode = vim.fn.mode(),
    reg = vim.fn.getreg('"'), regtype = vim.fn.getregtype('"'),
    err = (not ok) and tostring(err) or vim.NIL,
  }
  pcall(vim.api.nvim_feedkeys, term('<Esc><Esc>'), 'nx', false)
  for k, _ in pairs(c.opts or {}) do vim.o[k] = vim.api.nvim_get_option_info2(k, {}).default end
  out:write(vim.json.encode(result) .. '\n')
end
out:close()
