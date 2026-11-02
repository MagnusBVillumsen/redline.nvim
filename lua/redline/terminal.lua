local config = require 'redline.config'

local M = {}

---@class redline.Term
---@field name string
---@field buf integer
---@field chan integer
---@field cwd string

---@type table<string, redline.Term>
M.sessions = {}

---@param t redline.Term
---@return boolean
function M.alive(t)
  return vim.api.nvim_buf_is_valid(t.buf) and vim.fn.jobwait({ t.chan }, 0)[1] == -1
end

---@param t redline.Term
---@return integer?
function M.win(t)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == t.buf then
      return w
    end
  end
end

---@return integer
local function open_split()
  local o = config.options.agent.win
  local vert = o.position == 'right' or o.position == 'left'
  local total = vert and vim.o.columns or vim.o.lines
  local size = o.size < 1 and math.floor(total * o.size) or o.size
  local mods = ({ right = 'botright vertical', left = 'topleft vertical', bottom = 'botright', top = 'topleft' })[o.position]
  vim.cmd(string.format('%s %dsplit', mods or 'botright vertical', size))
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].signcolumn = 'no'
  vim.wo[w][vert and 'winfixwidth' or 'winfixheight'] = true
  return w
end

---@param t redline.Term
---@param focus boolean
---@return integer win
function M.show(t, focus)
  local w = M.win(t)
  local prev = vim.api.nvim_get_current_win()
  if not w then
    w = open_split()
    vim.api.nvim_win_set_buf(w, t.buf)
  end
  if focus then
    vim.api.nvim_set_current_win(w)
    vim.cmd.startinsert()
  elseif vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  return w
end

---@param t redline.Term
function M.hide(t)
  local w = M.win(t)
  if w and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_hide(w)
  end
end

---@param name string
---@param cmd string[]
---@param cwd string
---@param focus boolean
---@return redline.Term?
function M.spawn(name, cmd, cwd, focus)
  local prev = vim.api.nvim_get_current_win()
  local w = open_split()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(w, buf)
  local chan = vim.fn.jobstart(cmd, {
    term = true,
    cwd = cwd,
    on_exit = function()
      local t = M.sessions[name]
      if t and t.buf == buf then
        M.sessions[name] = nil
      end
    end,
  })
  if chan <= 0 then
    vim.api.nvim_win_close(w, true)
    return nil
  end
  vim.bo[buf].bufhidden = 'hide'
  vim.b[buf].redline_agent = name
  local t = { name = name, buf = buf, chan = chan, cwd = cwd }
  M.sessions[name] = t
  if focus then
    vim.cmd.startinsert()
  else
    vim.api.nvim_set_current_win(prev)
  end
  return t
end

--- Bracketed paste keeps newlines from submitting; Enter is sent after a
--- delay because some TUIs fold an Enter that arrives with the paste into it.
---@param t redline.Term
---@param text string
---@param submit boolean
function M.send(t, text, submit)
  vim.api.nvim_chan_send(t.chan, '\27[200~' .. text .. '\27[201~')
  if submit then
    vim.defer_fn(function()
      if M.alive(t) then
        vim.api.nvim_chan_send(t.chan, '\r')
      end
    end, config.options.agent.submit_delay)
  end
end

return M
