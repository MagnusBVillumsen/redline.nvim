local config = require 'redline.config'

local M = {}

local function agent()
  return require 'redline.agent'
end
local function review()
  return require 'redline.review'
end
local function inline()
  return require 'redline.inline'
end
local function pr()
  return require 'redline.pr'
end

---@param label? string
local function snap(label)
  local git = require 'redline.git'
  local util = require 'redline.util'
  local root = git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  local function go(l)
    local s, err = require('redline.snapshot').create(root, l)
    if s then
      util.notify('Snapshot #' .. s.n .. ': ' .. s.label)
    else
      util.err('Snapshot failed: ' .. (err or ''))
    end
  end
  if label then
    return go(label)
  end
  vim.ui.input({ prompt = 'Snapshot label: ' }, function(l)
    if l then
      go(l)
    end
  end)
end

local function snapshots()
  local git = require 'redline.git'
  local root = git.root()
  if root then
    require('redline.snapshot').pick(root, function(s)
      inline().enable { root = root, rev = s.sha, label = 'snapshot #' .. s.n }
    end)
  end
end

---@class redline.Sub
---@field run fun(args: string[], cmd: table)
---@field complete? fun(): string[]

---@type table<string, redline.Sub>
M.subs = {
  toggle = {
    run = function(a)
      agent().toggle { name = a[1], focus = true }
    end,
    complete = function()
      return vim.tbl_keys(config.options.agent.tools)
    end,
  },
  select = {
    run = function()
      agent().select()
    end,
  },
  focus = {
    run = function()
      agent().focus()
    end,
  },
  send = {
    run = function(a, cmd)
      local ctx = require 'redline.context'
      if #a > 0 then
        return agent().send(table.concat(a, ' '), { submit = false })
      end
      local c = ctx.get()
      if cmd.range > 0 then
        local lines = vim.api.nvim_buf_get_lines(c.buf, cmd.line1 - 1, cmd.line2, false)
        c.sel = { l1 = cmd.line1, l2 = cmd.line2, text = table.concat(lines, '\n'), mode = 'V' }
      end
      agent().send(ctx.selection(c), { submit = false })
    end,
  },
  prompt = {
    run = function(a)
      agent().prompt(a[1])
    end,
    complete = function()
      return vim.tbl_keys(config.options.agent.prompts)
    end,
  },
  comment = {
    run = function(a, cmd)
      local text = #a > 0 and table.concat(a, ' ') or nil
      if cmd.range > 0 then
        return review().add { l1 = cmd.line1, l2 = cmd.line2, text = text }
      end
      review().add { text = text }
    end,
  },
  edit = {
    run = function()
      review().edit()
    end,
  },
  delete = {
    run = function()
      review().delete()
    end,
  },
  comments = {
    run = function()
      review().list()
    end,
  },
  pick = {
    run = function()
      review().pick()
    end,
  },
  review = {
    run = function()
      review().send()
    end,
  },
  check = {
    run = function()
      review().check()
    end,
  },
  clear = {
    run = function(a)
      review().clear { all = a[1] == 'all' }
    end,
    complete = function()
      return { 'sent', 'all' }
    end,
  },
  snapshot = {
    run = function(a)
      snap(#a > 0 and table.concat(a, ' ') or nil)
    end,
  },
  snapshots = { run = snapshots },
  diff = {
    run = function(a)
      if a[1] then
        return inline().enable { rev = a[1] }
      end
      inline().toggle()
    end,
    complete = function()
      return { 'HEAD', 'HEAD~1', 'main', 'master' }
    end,
  },
  base = {
    run = function()
      inline().pick()
    end,
  },
  off = {
    run = function()
      inline().disable()
    end,
  },
  files = {
    run = function()
      inline().files()
    end,
  },
  qf = {
    run = function()
      inline().refresh { qf = true }
      vim.cmd.copen()
    end,
  },
  next = {
    run = function()
      inline().nav(1)
    end,
  },
  prev = {
    run = function()
      inline().nav(-1)
    end,
  },
  pr = {
    run = function(a)
      pr().open(tonumber(a[1]))
    end,
  },
  submit = {
    run = function(a)
      pr().submit { event = a[1], body = a[2] and table.concat(a, ' ', 2) or nil }
    end,
    complete = function()
      return { 'comment', 'approve', 'request_changes' }
    end,
  },
  close = {
    run = function()
      pr().close()
    end,
  },
  reload = {
    run = function(_, cmd)
      local buf = vim.api.nvim_get_current_buf()
      if not cmd.bang and vim.bo[buf].modified then
        return require('redline.util').warn 'Buffer has unsaved changes; :Redline reload! drops them'
      end
      require('redline.watch').reload(buf, cmd.bang)
    end,
  },
  diskdiff = {
    run = function()
      require('redline.watch').diskdiff()
    end,
  },
}

---@param opts table
function M.command(opts)
  local name = opts.fargs[1]
  -- `:Redline reload!` reads naturally, so a trailing `!` counts as a bang.
  if name and name:sub(-1) == '!' then
    name = name:sub(1, -2)
    opts = vim.tbl_extend('force', opts, { bang = true })
  end
  local sub = name and M.subs[name]
  if not sub then
    return vim.notify('Redline: unknown subcommand ' .. tostring(name), vim.log.levels.ERROR)
  end
  sub.run(vim.list_slice(opts.fargs, 2), opts)
end

---@param lead string
---@param line string
---@return string[]
function M.complete(lead, line)
  local words = vim.split(line, '%s+', { trimempty = true })
  local n = #words + (line:match '%s$' and 1 or 0)
  local list
  if n <= 2 then
    list = vim.tbl_keys(M.subs)
  else
    local sub = M.subs[words[2]]
    list = sub and sub.complete and sub.complete() or {}
  end
  table.sort(list)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, lead)
  end, list)
end

---@class redline.Key
---@field [1] string mode(s)
---@field [2] function
---@field [3] string desc

---@type table<string, redline.Key>
local keys = {
  toggle = {
    'n',
    function()
      agent().toggle()
    end,
    'Agent toggle',
  },
  select = {
    'n',
    function()
      agent().select()
    end,
    'Agent select',
  },
  codex = {
    'n',
    function()
      agent().toggle { name = 'codex', focus = true }
    end,
    'Agent Codex',
  },
  claude = {
    'n',
    function()
      agent().toggle { name = 'claude', focus = true }
    end,
    'Agent Claude',
  },
  send = {
    'x',
    function()
      agent().send_selection()
    end,
    'Send selection to agent',
  },
  prompt = {
    'nx',
    function()
      agent().prompt()
    end,
    'Agent prompt',
  },
  focus = {
    'ntix',
    function()
      agent().focus()
    end,
    'Agent focus',
  },
  comment = {
    'nx',
    function()
      review().add()
    end,
    'Review comment',
  },
  edit = {
    'n',
    function()
      review().edit()
    end,
    'Edit comment',
  },
  delete = {
    'n',
    function()
      review().delete()
    end,
    'Delete comment',
  },
  list = {
    'n',
    function()
      review().list()
    end,
    'List comments',
  },
  review_send = {
    'n',
    function()
      review().send()
    end,
    'Send review to agent',
  },
  review_check = {
    'n',
    function()
      review().check()
    end,
    'Check review vs snapshot',
  },
  snapshot = {
    'n',
    function()
      snap()
    end,
    'Snapshot',
  },
  diff = {
    'n',
    function()
      inline().toggle()
    end,
    'Inline diff toggle',
  },
  diff_pick = {
    'n',
    function()
      inline().pick()
    end,
    'Inline diff against…',
  },
  files = {
    'n',
    function()
      inline().files()
    end,
    'Changed files',
  },
  pr = {
    'n',
    function()
      pr().open()
    end,
    'PR review',
  },
  pr_submit = {
    'n',
    function()
      pr().submit()
    end,
    'PR submit review',
  },
  next_hunk = {
    'n',
    function()
      inline().nav(1)
    end,
    'Next hunk (all files)',
  },
  prev_hunk = {
    'n',
    function()
      inline().nav(-1)
    end,
    'Previous hunk (all files)',
  },
}

local function map_keys()
  local k = config.options.keys
  if not k then
    return
  end
  for name, lhs in pairs(k) do
    local spec = keys[name]
    if spec and lhs then
      local modes = vim.split(spec[1], '')
      vim.keymap.set(modes, lhs, spec[2], { desc = spec[3] })
    end
  end
  local ok, wk = pcall(require, 'which-key')
  if ok and wk.add then
    wk.add {
      { '<leader>a', group = '[A]gent', mode = { 'n', 'x' } },
      { '<leader>r', group = '[R]edline review', mode = { 'n', 'x' } },
    }
  end
end

---@param opts? table
function M.setup(opts)
  config.setup(opts)
  map_keys()
  require('redline.render').highlights()
  require('redline.watch').setup()
  local group = vim.api.nvim_create_augroup('redline', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      require('redline.render').highlights()
    end,
  })
  vim.api.nvim_create_autocmd('BufReadPre', {
    group = group,
    callback = function(ev)
      -- A reload replaces all lines, so tracked marks are not trustworthy.
      review().marks[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, {
    group = group,
    callback = function(ev)
      if not review().marks[ev.buf] then
        review().draw(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'VimLeavePre' }, {
    group = group,
    callback = function(ev)
      local root = require('redline.git').root(ev.file ~= '' and ev.file or nil)
      if root then
        review().sync(root)
      end
    end,
  })
end

return M
