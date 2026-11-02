local config = require 'redline.config'
local diff = require 'redline.diff'
local git = require 'redline.git'
local render = require 'redline.render'
local util = require 'redline.util'

local M = {}

M.ns = vim.api.nvim_create_namespace 'redline.comments'

---@class redline.SnapRef
---@field n integer
---@field ref string
---@field sha string

---@class redline.PrRef
---@field backend string
---@field number integer

---@class redline.Comment
---@field id integer
---@field path string
---@field l1 integer
---@field l2 integer
---@field text string
---@field code string[]
---@field ft string
---@field created integer
---@field sent? integer
---@field snapshot? redline.SnapRef
---@field pr? redline.PrRef

---@class redline.Db
---@field next_id integer
---@field comments redline.Comment[]

---@type table<string, redline.Db>
M.dbs = {}

--- Extmark ids per buffer and comment: { start, end }.
---@type table<integer, table<integer, integer[]>>
M.marks = {}

---@param root string
---@return string
function M.file(root)
  return config.state_dir() .. '/comments/' .. root:gsub('[/\\:]', '%%') .. '.json'
end

---@param root string
---@return redline.Db
function M.db(root)
  if not M.dbs[root] then
    local data = util.json(util.read(M.file(root)) or '')
    M.dbs[root] = (type(data) == 'table' and data.comments) and data or { next_id = 1, comments = {} }
  end
  return M.dbs[root]
end

---@param root string
function M.save(root)
  util.write(M.file(root), vim.json.encode(M.db(root)))
end

---@param root string
---@param path string
---@return integer?
local function loaded_buf(root, path)
  local b = vim.fn.bufnr(root .. '/' .. path)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
end

--- Pulls tracked extmark positions back into the store.
---@param root string
function M.sync(root)
  local changed = false
  for _, c in ipairs(M.db(root).comments) do
    local b = loaded_buf(root, c.path)
    local m = b and M.marks[b] and M.marks[b][c.id]
    if m then
      local s = vim.api.nvim_buf_get_extmark_by_id(b, M.ns, m[1], {})
      local e = vim.api.nvim_buf_get_extmark_by_id(b, M.ns, m[2], {})
      if s[1] and e[1] then
        local l1, l2 = s[1] + 1, math.max(e[1] + 1, s[1] + 1)
        if l1 ~= c.l1 or l2 ~= c.l2 then
          c.l1, c.l2, changed = l1, l2, true
        end
      end
    end
  end
  if changed then
    M.save(root)
  end
end

---@param c redline.Comment
---@param prefix? [string, string]
---@param hl? string
---@return [string, string][][]
function M.virt(c, prefix, hl)
  hl = hl or 'RedlineComment'
  local sign = config.options.review.sign
  local out = {}
  for i, line in ipairs(vim.split(c.text, '\n', { plain = true })) do
    local row = { { ' ' .. sign .. ' ', 'RedlineCommentSign' } }
    if i == 1 then
      if prefix then
        row[#row + 1] = prefix
      end
      row[#row + 1] = { string.format('#%d L%s ', c.id, util.range(c.l1, c.l2)), hl }
    end
    row[#row + 1] = { line .. string.rep(' ', math.max(vim.o.columns - #line - 20, 1)), hl }
    out[#out + 1] = row
  end
  return out
end

---@param buf integer
---@param c redline.Comment
---@param l1 integer
---@param l2 integer
---@param prefix? [string, string]
---@return integer[]
function M.place(buf, c, l1, l2, prefix)
  local n = vim.api.nvim_buf_line_count(buf)
  l1, l2 = math.min(l1, n), math.min(l2, n)
  local s = vim.api.nvim_buf_set_extmark(buf, M.ns, l1 - 1, 0, {
    sign_text = config.options.review.sign,
    sign_hl_group = 'RedlineCommentSign',
    priority = 200,
  })
  local e = vim.api.nvim_buf_set_extmark(buf, M.ns, l2 - 1, 0, {
    virt_lines = M.virt(c, prefix),
    priority = 200,
  })
  return { s, e }
end

---@param c redline.Comment
---@return boolean
local function pending(c)
  if c.sent then
    return false
  end
  local pr = require('redline.pr').state
  if c.pr then
    return pr ~= nil and pr.number == c.pr.number
  end
  return true
end

---@param buf integer
function M.draw(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local root = name ~= '' and git.root(name)
  if not root then
    return
  end
  local rel = git.rel(root, name)
  if M.marks[buf] then
    M.sync(root)
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  M.marks[buf] = {}
  for _, c in ipairs(M.db(root).comments) do
    if c.path == rel and pending(c) then
      M.marks[buf][c.id] = M.place(buf, c, c.l1, c.l2)
    end
  end
end

---@param root string
function M.redraw(root)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= '' and git.rel(root, name) then
        M.draw(b)
      end
    end
  end
end

--- Floating editor; <C-s>, :w or <CR> in normal mode save, q/<Esc> cancel.
---@param title string
---@param text string
---@param cb fun(text: string)
function M.editor(title, text, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_name(buf, 'redline://comment/' .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  local w = math.min(80, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = w,
    height = 6,
    border = 'rounded',
    title = ' ' .. title .. ' ',
    footer = ' <C-s> save · q cancel ',
    style = 'minimal',
  })
  vim.wo[win].wrap = true
  local done = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  local function save()
    if done then
      return
    end
    done = true
    local t = util.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    vim.cmd.stopinsert()
    close()
    if t ~= '' then
      cb(t)
    end
  end
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = save })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', save, { buffer = buf })
  vim.keymap.set('n', '<CR>', save, { buffer = buf })
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  if text == '' then
    vim.cmd.startinsert()
  end
end

---@class redline.AddOpts
---@field buf? integer
---@field l1? integer
---@field l2? integer
---@field text? string Skips the editor

---@param opts? redline.AddOpts
---@return redline.Comment?
function M.add(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local l1, l2 = opts.l1, opts.l2
  if not l1 then
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' or mode == '\22' then
      local a, b = vim.fn.line 'v', vim.fn.line '.'
      l1, l2 = math.min(a, b), math.max(a, b)
      vim.cmd.normal { vim.keycode '<Esc>', bang = true }
    else
      l1 = vim.api.nvim_win_get_cursor(0)[1]
    end
  end
  l2 = l2 or l1
  local name = vim.api.nvim_buf_get_name(buf)
  local root = name ~= '' and git.root(name)
  local rel = root and git.rel(root, name)
  if not root or not rel then
    util.err 'Comments need a file inside a git repository'
    return nil
  end
  local function create(text)
    local db = M.db(root)
    local pr = require('redline.pr').state
    ---@type redline.Comment
    local c = {
      id = db.next_id,
      path = rel,
      l1 = l1,
      l2 = l2,
      text = text,
      code = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false),
      ft = vim.bo[buf].filetype,
      created = os.time(),
      pr = pr and { backend = pr.backend, number = pr.number } or nil,
    }
    db.next_id = db.next_id + 1
    table.insert(db.comments, c)
    M.save(root)
    render.highlights()
    M.draw(buf)
    return c
  end
  if opts.text then
    return create(opts.text)
  end
  M.editor(string.format('Comment %s:%s', rel, util.range(l1, l2)), '', create)
end

---@param buf? integer
---@return redline.Comment?, string?
function M.at_cursor(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local root = name ~= '' and git.root(name)
  if not root then
    return nil
  end
  M.sync(root)
  local rel = git.rel(root, name)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, c in ipairs(M.db(root).comments) do
    if c.path == rel and pending(c) and row >= c.l1 and row <= c.l2 then
      if not best or (c.l2 - c.l1) < (best.l2 - best.l1) then
        best = c
      end
    end
  end
  return best, root
end

---@param id? integer
function M.edit(id)
  local c, root = M.at_cursor()
  if id and root then
    c = M.get(root, id)
  end
  if not c or not root then
    return util.warn 'No comment here'
  end
  M.editor('Edit #' .. c.id, c.text, function(t)
    c.text = t
    M.save(root)
    M.redraw(root)
  end)
end

---@param root string
---@param id integer
---@return redline.Comment?
function M.get(root, id)
  for _, c in ipairs(M.db(root).comments) do
    if c.id == id then
      return c
    end
  end
end

---@param id? integer
function M.delete(id)
  local c, root = M.at_cursor()
  if id and root then
    c = M.get(root, id)
  end
  if not c or not root then
    return util.warn 'No comment here'
  end
  M.remove(root, { c.id })
  M.redraw(root)
end

---@param root string
---@param ids integer[]
function M.remove(root, ids)
  local set = {}
  for _, i in ipairs(ids) do
    set[i] = true
  end
  local db = M.db(root)
  db.comments = vim.tbl_filter(function(c)
    return not set[c.id]
  end, db.comments)
  M.save(root)
end

--- Pending comments in scope: review comments, or the active PR's.
---@param root string
---@param pr? integer
---@return redline.Comment[]
function M.pending(root, pr)
  M.sync(root)
  local res = vim.tbl_filter(function(c)
    if c.sent then
      return false
    end
    if pr then
      return c.pr ~= nil and c.pr.number == pr
    end
    return c.pr == nil
  end, M.db(root).comments)
  table.sort(res, function(a, b)
    return a.path == b.path and a.l1 < b.l1 or a.path < b.path
  end)
  return res
end

--- Re-reads the commented code from the buffer or disk.
---@param root string
---@param c redline.Comment
function M.refresh_code(root, c)
  local b = loaded_buf(root, c.path)
  local lines = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or util.lines(util.read(root .. '/' .. c.path) or '')
  if #lines >= c.l2 then
    c.code = vim.list_slice(lines, c.l1, c.l2)
  end
end

---@param comments redline.Comment[]
---@return string
function M.format(comments)
  local out = { (config.options.review.header:gsub('{count}', tostring(#comments))) }
  for i, c in ipairs(comments) do
    out[#out + 1] = ''
    out[#out + 1] = string.format('## %d. %s:%s', i, c.path, util.range(c.l1, c.l2))
    out[#out + 1] = ''
    out[#out + 1] = util.codeblock(table.concat(c.code, '\n'), c.ft)
    out[#out + 1] = ''
    out[#out + 1] = c.text
  end
  return table.concat(out, '\n') .. '\n'
end

---@param root? string
function M.list(root)
  root = root or git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  M.sync(root)
  local items = {}
  for _, c in ipairs(M.db(root).comments) do
    local state = c.sent and ('sent → snapshot #' .. (c.snapshot and c.snapshot.n or '?')) or (c.pr and ('PR #' .. c.pr.number) or 'pending')
    items[#items + 1] = {
      filename = root .. '/' .. c.path,
      lnum = c.l1,
      end_lnum = c.l2,
      text = string.format('#%d [%s] %s', c.id, state, (c.text:gsub('\n', ' '))),
    }
  end
  vim.fn.setqflist({}, ' ', { title = 'redline comments', items = items })
  vim.cmd.copen()
end

--- Picker over pending comments.
function M.pick()
  local root = git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  local pr = require('redline.pr').state
  local list = M.pending(root, pr and pr.number)
  if #list == 0 then
    return util.notify 'No pending comments'
  end
  vim.ui.select(list, {
    prompt = 'Comments',
    format_item = function(c)
      return string.format('#%d %s:%s  %s', c.id, c.path, util.range(c.l1, c.l2), (c.text:gsub('\n', ' ')))
    end,
  }, function(c)
    if c then
      vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. c.path))
      pcall(vim.api.nvim_win_set_cursor, 0, { c.l1, 0 })
    end
  end)
end

--- Snapshots the tree, then sends all pending comments as one prompt.
---@param opts? {root?: string, submit?: boolean}
---@return boolean
function M.send(opts)
  opts = opts or {}
  local root = opts.root or git.root()
  if not root then
    util.err 'Not in a git repository'
    return false
  end
  local list = M.pending(root)
  if #list == 0 then
    util.notify 'No pending review comments'
    return false
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].modified and vim.bo[b].buftype == '' and git.rel(root, vim.api.nvim_buf_get_name(b)) then
      util.warn 'Unsaved buffers: the snapshot uses the files on disk'
      break
    end
  end
  local snap, err = require('redline.snapshot').create(root, string.format('review: %d comment(s)', #list))
  if not snap then
    util.err('Snapshot failed: ' .. (err or ''))
    return false
  end
  for _, c in ipairs(list) do
    M.refresh_code(root, c)
  end
  local text = M.format(list)
  local submit = opts.submit
  if submit == nil then
    submit = config.options.review.submit
  end
  require('redline.agent').send(text, { submit = submit }, function(ok)
    if not ok then
      return
    end
    local now = os.time()
    for _, c in ipairs(list) do
      c.sent = now
      c.snapshot = { n = snap.n, ref = snap.ref, sha = snap.sha }
    end
    M.save(root)
    M.redraw(root)
    util.notify(string.format('Sent %d comment(s); snapshot #%d', #list, snap.n))
  end)
  return true
end

--- Comments sent with a snapshot, with their mapped location and status.
---@param root string
---@param sha string
---@return {c: redline.Comment, l1: integer, l2: integer, touched: boolean}[]
function M.status(root, sha)
  local res = {}
  local cache = {}
  for _, c in ipairs(M.db(root).comments) do
    if c.snapshot and c.snapshot.sha == sha then
      local h = cache[c.path]
      if not h then
        local old = util.lines(git.blob(root, sha, c.path) or '')
        local b = loaded_buf(root, c.path)
        local new = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or util.lines(util.read(root .. '/' .. c.path) or '')
        h = diff.hunks(old, new)
        cache[c.path] = h
      end
      local m = diff.map_range(h, c.l1, c.l2)
      res[#res + 1] = { c = c, l1 = m.l1, l2 = m.l2, touched = m.touched }
    end
  end
  return res
end

M.check_ns = vim.api.nvim_create_namespace 'redline.check'

--- Opens the inline diff against the snapshot taken when comments were sent,
--- with each comment at its mapped location.
---@param snap? redline.SnapRef|redline.Snapshot
function M.check(snap)
  local root = git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  if not snap then
    local latest
    for _, c in ipairs(M.db(root).comments) do
      if c.snapshot and (not latest or c.snapshot.n > latest.n) then
        latest = c.snapshot
      end
    end
    if not latest then
      return util.warn 'No sent review comments'
    end
    snap = latest
  end
  local inline = require 'redline.inline'
  if not inline.enable { root = root, rev = snap.sha, label = 'review snapshot #' .. snap.n } then
    return
  end
  local sha = snap.sha
  inline.overlay('review', {
    draw = function(buf, rel, hunks)
      vim.api.nvim_buf_clear_namespace(buf, M.check_ns, 0, -1)
      local n = vim.api.nvim_buf_line_count(buf)
      for _, c in ipairs(M.db(root).comments) do
        if c.path == rel and c.snapshot and c.snapshot.sha == sha then
          local m = diff.map_range(hunks, c.l1, c.l2)
          local prefix = m.touched and { '✓ touched ', 'RedlineTouched' } or { '✗ untouched ', 'RedlineUntouched' }
          vim.api.nvim_buf_set_extmark(buf, M.check_ns, math.min(m.l2, n) - 1, 0, { virt_lines = M.virt(c, prefix), priority = 300 })
        end
      end
    end,
    clear = function(buf)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, M.check_ns, 0, -1)
      end
    end,
  })
  local items = {}
  for _, s in ipairs(M.status(root, sha)) do
    items[#items + 1] = {
      filename = root .. '/' .. s.c.path,
      lnum = s.l1,
      text = string.format('#%d [%s] %s', s.c.id, s.touched and 'touched' or 'UNTOUCHED', (s.c.text:gsub('\n', ' '))),
    }
  end
  vim.fn.setqflist({}, ' ', { title = 'redline review check', items = items })
end

---@param opts? {all?: boolean}
function M.clear(opts)
  local root = git.root()
  if not root then
    return
  end
  local db = M.db(root)
  db.comments = vim.tbl_filter(function(c)
    return not (opts and opts.all) and not c.sent
  end, db.comments)
  M.save(root)
  M.redraw(root)
end

return M
