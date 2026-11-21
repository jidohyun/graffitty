-- Hold Graffitty presentation effects (sparks, camera zoom, ripples, ...) off
-- while this Neovim's pane is focused, from any condition you can express as
-- Lua: filetype, mode, a preview window, a plugin event.
--
-- Neovim prints OSC 4723 to its own terminal; Graffitty keeps one record per
-- hold id for the pane and turns the named effects off while that pane is
-- focused.
--
-- A hold ends with Neovim (`until = "process"`), with the pane (`"pane"`), or
-- only on release (`"clear"`). Works through ssh and tmux.
--
-- Effect names: camera, camera.zoom, camera.tilt, camera.drift, camera.shake,
-- camera.dof, sheet, sheet.curvature, sheet.ripple, sheet.splash,
-- sheet.gloss, sheet.shadow, lighting, sparks, cursor_trail, pane_zoom,
-- tab_switch, typing, all.
local M = {}
local placed = {}
local config = { enabled = nil }

local function names(value)
  if value == nil then return {} end
  if type(value) == "string" then
    local list = {}
    for name in value:gmatch("[^,%s]+") do table.insert(list, name) end
    return list
  end
  return value
end

-- Graffitty panes export GRAFFITTY_SOCKET; inside tmux the environment may be
-- stale, so tmux alone also counts. Other terminals ignore the sequence.
function M.enabled()
  if config.enabled ~= nil then return config.enabled end
  return (vim.env.GRAFFITTY_SOCKET ~= nil and vim.env.GRAFFITTY_SOCKET ~= "") or vim.env.TMUX ~= nil
end

local function wrap(sequence)
  if vim.env.TMUX and vim.env.TMUX ~= "" then
    return "\27Ptmux;" .. sequence:gsub("\27", "\27\27") .. "\27\\"
  end
  return sequence
end

-- The terminal sequence for a hold or release; nil when the request is invalid.
function M.encode(kind, id, opts)
  if kind == "release" then
    return wrap("\27]4723;effects;release" .. (id and ("=" .. id) or "") .. "\7")
  end
  if type(id) ~= "string" or not id:match("^[%w%._%-]+$") or #id > 64 then return nil end
  opts = opts or {}
  local off, on = names(opts.off), names(opts.on)
  if #off == 0 and #on == 0 then return nil end
  local body = "hold=" .. id
  if #off > 0 then body = body .. ";off=" .. table.concat(off, ",") end
  if #on > 0 then body = body .. ";on=" .. table.concat(on, ",") end
  local scope = opts["until"] or "process"
  if scope ~= "process" and scope ~= "pane" and scope ~= "clear" then return nil end
  if scope ~= "process" then body = body .. ";until=" .. scope end
  return wrap("\27]4723;effects;" .. body .. "\7")
end

-- Neovim's TUI shares stdout; OSC 52 clipboard support writes the same way.
function M.write(sequence)
  io.stdout:write(sequence)
  io.stdout:flush()
end

--- Turn effects off while this pane is focused.
--- `opts.off` / `opts.on`: list or comma-separated names. `opts["until"]`:
--- "process" (default), "pane" or "clear". Re-sending an id replaces the hold.
function M.hold(id, opts)
  if not M.enabled() then return false end
  local sequence = M.encode("hold", id, opts)
  if not sequence then
    vim.notify("graffitty.effects: invalid hold " .. vim.inspect({ id = id, opts = opts }), vim.log.levels.WARN)
    return false
  end
  placed[id] = true
  M.write(sequence)
  return true
end

--- Release one hold, or every hold of the pane when `id` is nil.
function M.release(id)
  if not M.enabled() then return false end
  if id == nil then placed = {} else placed[id] = nil end
  M.write(M.encode("release", id))
  return true
end

--- Hold while `condition()` is true, evaluated on each of `events`.
--- Example: effects.watch("md-preview", { "FileType", "BufEnter" }, function()
---   return vim.bo.filetype == "markdown" end, { off = { "sparks", "camera" } })
function M.watch(id, events, condition, opts)
  local group = vim.api.nvim_create_augroup("graffitty.effects." .. id, { clear = true })
  local active = false
  local function evaluate()
    local wanted = condition() and true or false
    if wanted == active then return end
    active = wanted
    if wanted then M.hold(id, opts) else M.release(id) end
  end
  vim.api.nvim_create_autocmd(events, { group = group, callback = vim.schedule_wrap(evaluate) })
  evaluate()
  return group
end

--- `opts.holds`: list of { id, off, on, until, events, when } entries handed to
--- `watch`; `when` defaults to "always on" (a hold placed at startup).
--- `opts.enabled`: force on/off instead of detecting the Graffitty environment.
function M.setup(opts)
  opts = opts or {}
  config.enabled = opts.enabled
  for _, hold in ipairs(opts.holds or {}) do
    if hold.when then
      M.watch(hold.id, hold.events or { "BufEnter", "FileType", "ModeChanged" }, hold.when, hold)
    else
      M.hold(hold.id, hold)
    end
  end
  -- Pane- and clear-scoped holds would outlive Neovim; leave nothing behind.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("graffitty.effects", { clear = true }),
    callback = function()
      for id in pairs(placed) do M.release(id) end
    end,
  })
end

return M
