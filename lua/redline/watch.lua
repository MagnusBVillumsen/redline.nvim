local config = require 'redline.config'
local util = require 'redline.util'

--- Reloads buffers whose files change on disk. Watches parent directories,
--- since tools that write via rename replace the inode a file watch is on.
local M = {}

---@class redline.DirWatch
---@field handle? uv.uv_fs_event_t
---@field bufs table<integer, true>

---@type table<string, redline.DirWatch>
M.dirs = {}
---@type table<integer, string> last seen stat per buffer
M.seen = {}
---@type table<integer, string> stat a warning was given for
M.warned = {}
---@type table<integer, true> buffers polled because no watcher could be made
M.polled = {}
M.diff_ns = vim.api.nvim_create_namespace 'redline.diskdiff'

local timers = {} ---@type table<integer, uv.uv_timer_t>
local poll ---@type uv.uv_timer_t?
local group ---@type integer?

---@param path string
---@return string?
local function stat(path)
  local s = vim.uv.fs_stat(path)
  return s and string.format('%d.%d:%d:%d', s.mtime.sec, s.mtime.nsec, s.size, s.ino) or nil
end

---@param buf integer
---@return string?
local function file(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  if vim.bo[buf].buftype ~= '' or not vim.bo[buf].buflisted then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:find '^%a[%w+.-]*://' then
    return nil
  end
  return vim.fs.normalize(name)
end

local function count()
  local n = 0
  for _, d in pairs(M.dirs) do
    if d.handle then
      n = n + 1
    end
  end
  return n
end

local function ensure_poll()
  local iv = config.options.watch.poll
  if poll or iv <= 0 then
    return
  end
  poll = assert(vim.uv.new_timer())
  poll:start(iv, iv, vim.schedule_wrap(M.check_all))
end

---@param buf integer
local function schedule(buf)
  local t = timers[buf]
  if not t then
    t = assert(vim.uv.new_timer())
    timers[buf] = t
  end
  t:stop()
  t:start(config.options.watch.debounce, 0, function()
    vim.schedule(function()
      M.check(buf)
    end)
  end)
end

local function kick_inline()
  local inline = package.loaded['redline.inline']
  if inline and inline.active() then
    inline.kick()
  end
end

---@param dir string
---@return boolean
local function arm(dir)
  local d = M.dirs[dir]
  if d.handle then
    return true
  end
  if count() >= config.options.watch.max then
    return false
  end
  local h = vim.uv.new_fs_event()
  if not h then
    return false
  end
  local ok = h:start(dir, {}, function(err, name)
    vim.schedule(function()
      local cur = M.dirs[dir]
      if not cur then
        return
      end
      if err then
        -- The directory went away or was replaced: re-arm, else poll.
        if cur.handle then
          cur.handle:close()
          cur.handle = nil
        end
        if not arm(dir) then
          for b in pairs(cur.bufs) do
            M.polled[b] = true
          end
          ensure_poll()
        end
      end
      for b in pairs(cur.bufs) do
        local f = file(b)
        if f and (not name or err or vim.fs.basename(f) == name) then
          schedule(b)
        end
      end
      kick_inline()
    end)
  end)
  if not ok then
    h:close()
    return false
  end
  d.handle = h
  return true
end

---@param buf integer
function M.track(buf)
  if not config.options.watch.enabled then
    return
  end
  local f = file(buf)
  if not f then
    return
  end
  local dir = vim.fs.dirname(f)
  for d, w in pairs(M.dirs) do
    if d ~= dir and w.bufs[buf] then
      M.untrack(buf)
      break
    end
  end
  M.seen[buf] = stat(f)
  M.warned[buf] = nil
  M.dirs[dir] = M.dirs[dir] or { bufs = {} }
  M.dirs[dir].bufs[buf] = true
  if arm(dir) then
    M.polled[buf] = nil
  else
    M.polled[buf] = true
    ensure_poll()
  end
end

---@param buf integer
function M.untrack(buf)
  for dir, d in pairs(M.dirs) do
    if d.bufs[buf] then
      d.bufs[buf] = nil
      if not next(d.bufs) then
        if d.handle then
          d.handle:close()
        end
        M.dirs[dir] = nil
      end
    end
  end
  if timers[buf] then
    timers[buf]:close()
    timers[buf] = nil
  end
  M.seen[buf], M.warned[buf], M.polled[buf] = nil, nil, nil
end

--- Reloads a buffer from disk, keeping the view of every window on it.
---@param buf integer
---@param force? boolean Drop unsaved changes
---@return boolean
function M.reload(buf, force)
  local f = file(buf)
  if not f or (vim.bo[buf].modified and not force) then
    return false
  end
  local views = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd 'silent! keepjumps edit!'
  end)
  for w, v in pairs(views) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function()
        vim.fn.winrestview(v)
      end)
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, M.diff_ns, 0, -1)
  M.seen[buf] = stat(f)
  M.warned[buf] = nil
  return true
end

--- Reloads the buffer if its file changed; never touches unsaved changes.
---@param buf integer
function M.check(buf)
  local f = file(buf)
  if not f then
    return
  end
  local st = stat(f)
  if not st or st == M.seen[buf] then
    return
  end
  if not vim.bo[buf].modified then
    M.reload(buf)
    return
  end
  if M.warned[buf] ~= st then
    M.warned[buf] = st
    util.warn(
      string.format(
        '%s changed on disk, but the buffer has unsaved changes. :Redline reload! loads the disk version, :Redline diskdiff shows the difference.',
        vim.fn.fnamemodify(f, ':~:.')
      )
    )
  end
end

function M.check_all()
  if not config.options.watch.enabled then
    return
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if M.seen[b] then
      M.check(b)
    end
  end
end

--- Shows the disk version of a modified buffer as an inline diff.
---@param buf? integer
function M.diskdiff(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local f = file(buf)
  if not f then
    return util.warn 'Not a file buffer'
  end
  if #vim.api.nvim_buf_get_extmarks(buf, M.diff_ns, 0, -1, { limit = 1 }) > 0 then
    vim.api.nvim_buf_clear_namespace(buf, M.diff_ns, 0, -1)
    return
  end
  local disk = util.lines(util.read(f) or '')
  local hunks = require('redline.diff').hunks(disk, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  require('redline.render').highlights()
  require('redline.render').draw(buf, hunks, { old = disk, ns = M.diff_ns })
  util.notify(string.format('%d hunk(s) vs disk: red is the disk version, green your buffer', #hunks))
end

function M.setup()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  if not config.options.watch.enabled then
    M.stop()
    return
  end
  group = vim.api.nvim_create_augroup('redline.watch', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'BufFilePost', 'BufAdd' }, {
    group = group,
    callback = function(ev)
      M.track(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout', 'BufUnload' }, {
    group = group,
    callback = function(ev)
      M.untrack(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
    group = group,
    callback = function()
      vim.schedule(M.check_all)
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    M.track(b)
  end
end

function M.stop()
  for b in pairs(M.seen) do
    M.untrack(b)
  end
  for dir, d in pairs(M.dirs) do
    if d.handle then
      d.handle:close()
    end
    M.dirs[dir] = nil
  end
  if poll then
    poll:close()
    poll = nil
  end
end

return M
