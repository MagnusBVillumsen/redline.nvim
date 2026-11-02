local config = require 'redline.config'
local diff = require 'redline.diff'
local git = require 'redline.git'
local render = require 'redline.render'
local snapshot = require 'redline.snapshot'
local util = require 'redline.util'

local M = {}

---@class redline.Overlay
---@field draw fun(buf: integer, rel: string, hunks: redline.Hunk[])
---@field clear fun(buf: integer)

---@class redline.Item
---@field path string
---@field status string
---@field lnum integer
---@field text string

---@class redline.InlineState
---@field root string
---@field rev string
---@field sha string
---@field label string
---@field changes redline.Change[]
---@field items redline.Item[]
---@field hunks table<integer, redline.Hunk[]>
---@field old table<string, string[]|false>
---@field overlays table<string, redline.Overlay>
---@field group integer
---@field timer? uv.uv_timer_t
---@field redraw table<integer, function>

---@type redline.InlineState?
M.state = nil

local QF_TITLE = 'redline diff'

---@return boolean
function M.active()
  return M.state ~= nil
end

---@param path string
---@return string[]|false
local function old_lines(path)
  local s = assert(M.state)
  if s.old[path] == nil then
    local content = git.blob(s.root, s.sha, path)
    if content and (#content > config.options.diff.max_bytes or content:find('\0', 1, true)) then
      s.old[path] = false
    else
      s.old[path] = util.lines(content or '')
    end
  end
  return s.old[path]
end

---@param buf integer
---@return string?
local function buf_rel(buf)
  local s = M.state
  if not s or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  return git.rel(s.root, name)
end

--- Hunks of a buffer against the base; computed fresh.
---@param buf integer
---@return redline.Hunk[]?, string?
function M.buf_hunks(buf)
  local rel = buf_rel(buf)
  if not rel then
    return nil
  end
  local old = old_lines(rel)
  if old == false then
    return nil
  end
  return diff.hunks(old, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), rel
end

---@param buf integer
function M.draw(buf)
  local s = M.state
  if not s then
    return
  end
  local hunks, rel = M.buf_hunks(buf)
  if not hunks or not rel then
    return
  end
  s.hunks[buf] = hunks
  render.draw(buf, hunks, { old = s.old[rel] or nil })
  for _, ov in pairs(s.overlays) do
    ov.draw(buf, rel, hunks)
  end
end

---@param buf integer
function M.attach(buf)
  local s = M.state
  if not s or not buf_rel(buf) then
    return
  end
  if not s.redraw[buf] then
    s.redraw[buf] = util.debounce(function()
      M.draw(buf)
    end, config.options.diff.debounce)
    if config.options.diff.autoread then
      vim.bo[buf].autoread = true
    end
  end
  M.draw(buf)
end

---@param path string
---@return string[]
local function current_lines(path)
  local s = assert(M.state)
  local abs = s.root .. '/' .. path
  local buf = vim.fn.bufnr(abs)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return util.lines(util.read(abs) or '')
end

--- Recomputes changed files and their hunks.
---@param opts? {qf?: boolean}
function M.refresh(opts)
  local s = M.state
  if not s then
    return
  end
  local tree = snapshot.tree(s.root)
  s.changes = tree and git.changes(s.root, s.sha, tree) or {}
  local items = {}
  for _, c in ipairs(s.changes) do
    local old = c.status == 'A' and {} or old_lines(c.path)
    if c.status == 'D' then
      items[#items + 1] = { path = c.path, status = 'D', lnum = 1, text = 'deleted' }
    elseif old == false then
      items[#items + 1] = { path = c.path, status = c.status, lnum = 1, text = 'binary or large' }
    else
      for _, h in ipairs(diff.hunks(old, current_lines(c.path))) do
        items[#items + 1] = {
          path = c.path,
          status = c.status,
          lnum = math.max(h.new_start, 1),
          text = string.format('%s +%d -%d', c.status, h.new_count, h.old_count),
        }
      end
    end
  end
  s.items = items
  local info = vim.fn.getqflist { title = 0 }
  if (opts and opts.qf) or info.title == QF_TITLE then
    M.setqf(opts and opts.qf)
  end
end

--- Debounced refresh, driven by the file watcher.
M.kick = util.debounce(function()
  M.refresh()
end, 300)

---@param new? boolean
function M.setqf(new)
  local s = M.state
  if not s then
    return
  end
  local list = {}
  for _, it in ipairs(s.items) do
    list[#list + 1] = { filename = s.root .. '/' .. it.path, lnum = it.lnum, text = it.text }
  end
  vim.fn.setqflist({}, new and ' ' or 'r', { title = QF_TITLE, items = list })
end

local function tick()
  local s = M.state
  if not s then
    return
  end
  -- The watcher's check never prompts and never touches modified buffers,
  -- unlike a bare :checktime.
  if config.options.watch.enabled then
    require('redline.watch').check_all()
  elseif vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'c' then
    pcall(vim.cmd.checktime)
  end
  M.refresh()
end

---@class redline.EnableOpts
---@field root? string
---@field rev string
---@field label? string
---@field qf? boolean

---@param opts redline.EnableOpts
---@return boolean
function M.enable(opts)
  local root = opts.root or git.root()
  if not root then
    util.err 'Not in a git repository'
    return false
  end
  local sha = git.sha(root, opts.rev)
  if not sha then
    util.err('Unknown revision: ' .. opts.rev)
    return false
  end
  M.disable()
  render.highlights()
  local group = vim.api.nvim_create_augroup('redline.inline', { clear = true })
  M.state = {
    root = root,
    rev = opts.rev,
    sha = sha,
    label = opts.label or opts.rev,
    changes = {},
    items = {},
    hunks = {},
    old = {},
    overlays = {},
    group = group,
    redraw = {},
  }
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter', 'FileChangedShellPost' }, {
    group = group,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = function(ev)
      local f = M.state and M.state.redraw[ev.buf]
      if f then
        f()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'FocusGained' }, {
    group = group,
    callback = function()
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      M.redraw_all()
    end,
  })
  local iv = config.options.diff.interval
  if iv > 0 then
    local t = assert(vim.uv.new_timer())
    t:start(iv, iv, vim.schedule_wrap(tick))
    M.state.timer = t
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
  M.refresh { qf = opts.qf ~= false }
  util.notify(string.format('Diff vs %s: %d file(s) changed', M.state.label, #M.state.changes))
  return true
end

function M.redraw_all()
  if not M.state then
    return
  end
  for buf in pairs(M.state.redraw) do
    if vim.api.nvim_buf_is_valid(buf) then
      M.draw(buf)
    end
  end
end

function M.disable()
  local s = M.state
  if not s then
    return
  end
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, s.group)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    render.clear(buf)
    for _, ov in pairs(s.overlays) do
      ov.clear(buf)
    end
  end
  M.state = nil
end

---@param name string
---@param ov redline.Overlay?
function M.overlay(name, ov)
  if not M.state then
    return
  end
  local old = M.state.overlays[name]
  if old then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      old.clear(buf)
    end
  end
  M.state.overlays[name] = ov
  M.redraw_all()
end

---@param rev? string
function M.toggle(rev)
  if M.state and not rev then
    return M.disable()
  end
  M.enable { rev = rev or 'HEAD' }
end

--- All hunk positions across files, with live hunks for the current buffer.
---@return {path: string, lnum: integer}[]
local function positions()
  local s = assert(M.state)
  local cur = buf_rel(0)
  local res = {}
  for _, it in ipairs(s.items) do
    if it.path ~= cur then
      res[#res + 1] = { path = it.path, lnum = it.lnum }
    end
  end
  if cur then
    for _, h in ipairs(M.buf_hunks(0) or {}) do
      res[#res + 1] = { path = cur, lnum = math.max(h.new_start, 1) }
    end
  end
  table.sort(res, function(a, b)
    return a.path == b.path and a.lnum < b.lnum or a.path < b.path
  end)
  return res
end

---@param dir 1|-1
function M.nav(dir)
  local s = M.state
  if not s then
    return util.warn 'Inline diff is off (:Redline diff)'
  end
  local list = positions()
  if #list == 0 then
    return util.notify 'No changes'
  end
  local cur = buf_rel(0) or ''
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local function after(p)
    return p.path > cur or (p.path == cur and p.lnum > line)
  end
  local function before(p)
    return p.path < cur or (p.path == cur and p.lnum < line)
  end
  local target
  if dir > 0 then
    for _, p in ipairs(list) do
      if after(p) then
        target = p
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if before(list[i]) then
        target = list[i]
        break
      end
    end
    target = target or list[#list]
  end
  if target.path ~= cur then
    vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. target.path))
  end
  local n = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.lnum, n), 0 })
  vim.cmd 'normal! zz'
end

--- Picker over changed files.
function M.files()
  local s = M.state
  if not s then
    return util.warn 'Inline diff is off (:Redline diff)'
  end
  M.refresh()
  local counts = {}
  for _, it in ipairs(s.items) do
    counts[it.path] = (counts[it.path] or 0) + 1
  end
  vim.ui.select(s.changes, {
    prompt = 'Changed vs ' .. s.label,
    format_item = function(c)
      return string.format('%s %s (%d hunk%s)', c.status, c.path, counts[c.path] or 0, counts[c.path] == 1 and '' or 's')
    end,
  }, function(c)
    if c then
      vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. c.path))
      for _, it in ipairs(s.items) do
        if it.path == c.path then
          pcall(vim.api.nvim_win_set_cursor, 0, { it.lnum, 0 })
          break
        end
      end
    end
  end)
end

--- Pick a base: HEAD, merge-base with a branch, or a snapshot.
function M.pick()
  local root = git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  local items = { { label = 'HEAD', rev = 'HEAD' } }
  for _, b in ipairs { 'main', 'master', 'origin/main', 'origin/master' } do
    if git.sha(root, b) then
      local mb = git.ok(root, { 'merge-base', 'HEAD', b })
      if mb then
        items[#items + 1] = { label = 'merge-base ' .. b, rev = mb }
      end
    end
  end
  for _, sn in ipairs(snapshot.list(root)) do
    items[#items + 1] = { label = 'snapshot ' .. snapshot.format(sn), rev = sn.sha }
  end
  vim.ui.select(items, {
    prompt = 'Diff against',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      M.enable { root = root, rev = i.rev, label = i.label }
    end
  end)
end

return M
