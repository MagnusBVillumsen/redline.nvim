local util = require 'redline.util'

local M = {}

---@param root string
---@param args string[]
---@param opts? {env?: table<string,string>, stdin?: string}
---@return redline.Result
function M.run(root, args, opts)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  return util.run(cmd, opts)
end

---@param root string
---@param args string[]
---@param opts? {env?: table<string,string>, stdin?: string}
---@return string?, string?
function M.ok(root, args, opts)
  local r = M.run(root, args, opts)
  if r.code ~= 0 then
    return nil, util.trim(r.stderr)
  end
  return util.trim(r.stdout)
end

---@type table<string, string|false>
M.roots = {}

---@param path? string File or directory; defaults to the current buffer or cwd
---@return string?
function M.root(path)
  if not path or path == '' then
    local name = vim.api.nvim_buf_get_name(0)
    path = (name ~= '' and vim.bo.buftype == '') and name or vim.fn.getcwd()
  end
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  while dir and vim.fn.isdirectory(dir) == 0 do
    local up = vim.fs.dirname(dir)
    if up == dir then
      break
    end
    dir = up
  end
  local hit = M.roots[dir]
  if hit ~= nil then
    return hit or nil
  end
  local r = M.ok(dir, { 'rev-parse', '--show-toplevel' })
  local root = r and vim.fs.normalize(r) or nil
  M.roots[dir] = root or false
  return root
end

---@param root string
---@param abs string
---@return string?
function M.rel(root, abs)
  abs = vim.fs.normalize(abs)
  if abs:sub(1, #root + 1) == root .. '/' then
    return abs:sub(#root + 2)
  end
  local real = vim.uv.fs_realpath(abs)
  local rroot = vim.uv.fs_realpath(root)
  if real and rroot and real:sub(1, #rroot + 1) == rroot .. '/' then
    return real:sub(#rroot + 2)
  end
end

---@param root string
---@param rev string
---@return string?
function M.sha(root, rev)
  return (M.ok(root, { 'rev-parse', '--verify', '-q', rev .. '^{commit}' }))
end

---@param root string
---@param name string
---@return string
function M.path(root, name)
  local p = M.ok(root, { 'rev-parse', '--path-format=absolute', '--git-path', name })
  return p or (root .. '/.git/' .. name)
end

--- Name of the worktree, "main" for the primary one.
---@param root string
---@return string
function M.worktree(root)
  local gd = M.ok(root, { 'rev-parse', '--path-format=absolute', '--git-dir' }) or ''
  local cd = M.ok(root, { 'rev-parse', '--path-format=absolute', '--git-common-dir' }) or ''
  if gd == cd then
    return 'main'
  end
  return (vim.fs.basename(gd):gsub('[^%w._-]', '_'))
end

---@param root string
---@param sha string
---@param path string
---@return string? content, boolean? exists
function M.blob(root, sha, path)
  local r = M.run(root, { 'cat-file', 'blob', sha .. ':' .. path })
  if r.code ~= 0 then
    return nil, false
  end
  return r.stdout, true
end

---@param root string
---@return boolean
function M.dirty(root)
  local out = M.ok(root, { 'status', '--porcelain', '--untracked-files=no' })
  return out ~= nil and out ~= ''
end

---@class redline.Change
---@field status string A, M, D, T
---@field path string

---@param root string
---@param a string tree-ish
---@param b string tree-ish
---@return redline.Change[]
function M.changes(root, a, b)
  local out = M.ok(root, { 'diff-tree', '-r', '-z', '--no-renames', '--name-status', a, b }) or ''
  local parts = vim.split(out, '\0', { plain = true })
  local res = {}
  local i = 1
  while i < #parts do
    local st, p = parts[i], parts[i + 1]
    if st ~= '' and p and p ~= '' then
      res[#res + 1] = { status = st:sub(1, 1), path = p }
    end
    i = i + 2
  end
  table.sort(res, function(x, y)
    return x.path < y.path
  end)
  return res
end

return M
