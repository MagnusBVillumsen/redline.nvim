local config = require 'redline.config'
local git = require 'redline.git'
local util = require 'redline.util'

local M = {}

---@class redline.Snapshot
---@field n integer
---@field ref string
---@field sha string
---@field time integer
---@field label string

local ident = {
  GIT_AUTHOR_NAME = 'redline',
  GIT_AUTHOR_EMAIL = 'redline@localhost',
  GIT_COMMITTER_NAME = 'redline',
  GIT_COMMITTER_EMAIL = 'redline@localhost',
}

---@param root string
---@return string
function M.prefix(root)
  return 'refs/redline/snapshots/' .. git.worktree(root) .. '/'
end

--- Tree of the working tree including untracked, non-ignored files. Uses a
--- copy of the real index so stat info makes `add -A` fast and the real index
--- is never written.
---@param root string
---@return string? tree, string? err
function M.tree(root)
  local idx = vim.fn.tempname() .. '.redline-index'
  local real = git.path(root, 'index')
  local st = vim.uv.fs_stat(real)
  if st then
    vim.uv.fs_copyfile(real, idx)
    -- Git spots "racily clean" entries by comparing them with the index
    -- mtime; a fresh copy would hide same-second, same-size edits.
    vim.uv.fs_utime(idx, st.atime.sec + st.atime.nsec / 1e9, st.mtime.sec + st.mtime.nsec / 1e9)
  end
  local env = { GIT_INDEX_FILE = idx }
  local r = git.run(root, { 'add', '-A', '--', '.' }, { env = env })
  local tree, err
  if r.code == 0 then
    tree, err = git.ok(root, { 'write-tree' }, { env = env })
  else
    err = util.trim(r.stderr)
  end
  os.remove(idx)
  return tree, err
end

---@param root string
---@return redline.Snapshot[] newest first
function M.list(root)
  local pre = M.prefix(root)
  local fmt = '%(refname)%00%(objectname)%00%(committerdate:unix)%00%(subject)'
  local out = git.ok(root, { 'for-each-ref', '--format=' .. fmt, pre }) or ''
  local res = {}
  for _, line in ipairs(util.lines(out)) do
    local ref, sha, time, label = unpack(vim.split(line, '\0', { plain = true }))
    local n = tonumber(ref:sub(#pre + 1))
    if n then
      res[#res + 1] = { n = n, ref = ref, sha = sha, time = tonumber(time) or 0, label = label or '' }
    end
  end
  table.sort(res, function(a, b)
    return a.n > b.n
  end)
  return res
end

---@param root string
---@param keep? integer
function M.prune(root, keep)
  keep = keep or config.options.snapshot.keep
  for i, s in ipairs(M.list(root)) do
    if i > keep then
      git.run(root, { 'update-ref', '-d', s.ref })
    end
  end
end

---@param root string
---@param label? string
---@return redline.Snapshot? snap, string? err
function M.create(root, label)
  label = (label and label ~= '') and label or 'snapshot'
  local tree, err = M.tree(root)
  if not tree then
    return nil, err
  end
  local args = { 'commit-tree', tree, '-m', label }
  local head = git.sha(root, 'HEAD')
  if head then
    table.insert(args, 3, '-p')
    table.insert(args, 4, head)
  end
  local sha
  sha, err = git.ok(root, args, { env = ident })
  if not sha then
    return nil, err
  end
  local list = M.list(root)
  local n = (list[1] and list[1].n or 0) + 1
  local ref = M.prefix(root) .. n
  local _, uerr = git.ok(root, { 'update-ref', ref, sha })
  if uerr then
    return nil, uerr
  end
  M.prune(root)
  return { n = n, ref = ref, sha = sha, time = os.time(), label = label }
end

---@param s redline.Snapshot
---@return string
function M.format(s)
  return string.format('#%d  %s  %s', s.n, os.date('%Y-%m-%d %H:%M', s.time), s.label)
end

---@param root string
---@param cb fun(s: redline.Snapshot)
function M.pick(root, cb)
  local list = M.list(root)
  if #list == 0 then
    return util.warn 'No snapshots yet (:Redline snapshot)'
  end
  vim.ui.select(list, { prompt = 'Snapshot', format_item = M.format }, function(s)
    if s then
      cb(s)
    end
  end)
end

return M
