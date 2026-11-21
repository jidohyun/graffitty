-- Fyler names its buffer fyler-<scheme>://<displayed-root>. Publish that root
-- through Neovim's normal terminal title, including when the user visits a new
-- root without changing the owning shell's cwd. Works with existing configs.
local restore_root = vim.env.GRAFFITTY_FILETREE_ROOT
if restore_root == '' then restore_root = nil end
local function update()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local root = vim.api.nvim_buf_get_name(buffer):match('^fyler%-[^:]+://(.*)$')
    if root and root ~= '' and vim.api.nvim_buf_is_loaded(buffer) then
      if restore_root then
        local finder = package.loaded['fyler.finder']
        local instance = finder and finder.instance_get_or_nil()
        if instance then
          local requested = restore_root
          restore_root = nil -- Apply once; subsequent navigation belongs to the user.
          if requested ~= root then
            instance:visit({ path = requested })
            vim.schedule(update)
            return
          end
        end
      end
      vim.opt.title = true
      vim.opt.titlelen = 0 -- Preserve the full path; pane chrome handles clipping.
      vim.opt.titlestring = vim.fn.fnamemodify(root, ':~'):gsub('%%', '%%%%')
      vim.cmd.redrawstatus()
      return
    end
  end
end
vim.api.nvim_create_autocmd({ 'VimEnter', 'BufEnter', 'BufFilePost' }, {
  callback = function() vim.schedule(update) end,
})
