local config = require 'redline.config'
local util = require 'redline.util'

---@type redline.Backend
local M = { name = 'forge' }

---@param root string
---@param args string[]
---@return redline.Result
local function forge(root, args)
  local cmd = { config.options.pr.forge }
  vim.list_extend(cmd, args)
  return util.run(cmd, { cwd = root })
end

function M.list(root)
  local r = forge(root, { 'pr', 'list', '--json' })
  if r.code ~= 0 then
    return nil, util.trim(r.stderr)
  end
  local res = {}
  for _, p in ipairs(util.json(r.stdout) or {}) do
    res[#res + 1] = {
      number = p.number,
      title = p.title or '',
      author = p.user and p.user.login or '',
      head = p.head and p.head.ref or '',
      head_sha = p.head and p.head.sha or '',
      base = p.base and p.base.ref or '',
      url = p.html_url or '',
    }
  end
  return res
end

function M.checkout(root, n)
  local r = forge(root, { 'pr', 'checkout', tostring(n) })
  return r.code == 0, util.trim(r.stderr)
end

function M.comments(root, n)
  local r = forge(root, { 'pr', 'review', tostring(n), 'list', '--comments', '--json' })
  if r.code ~= 0 then
    return nil, util.trim(r.stderr)
  end
  local res = {}
  for _, rv in ipairs(util.json(r.stdout) or {}) do
    for _, c in ipairs(rv.comments or {}) do
      -- Forgejo puts the new-side line in `position` and the old-side one
      -- in `original_position`, with 0 for the side that does not apply.
      local new = (c.position or 0) > 0
      local line = new and c.position or c.original_position
      if c.path and line and line > 0 then
        res[#res + 1] = {
          path = c.path,
          line = line,
          side = new and 'new' or 'old',
          author = (c.user and c.user.login) or (rv.user and rv.user.login) or '?',
          body = c.body or '',
        }
      end
    end
  end
  return res
end

local flags = { approve = '--approve', request_changes = '--request-changes', comment = '--comment' }

function M.submit(root, n, rv)
  local comments = {}
  for _, c in ipairs(rv.comments) do
    comments[#comments + 1] = { path = c.path, line = c.l1, end_line = c.l2 > c.l1 and c.l2 or nil, side = 'new', body = c.text }
  end
  local args = { 'pr', 'review', tostring(n), 'submit', flags[rv.event] }
  local files = {}
  -- Files keep bodies that start with `-` from being read as flags.
  if rv.body and rv.body ~= '' then
    local bf = vim.fn.tempname() .. '.md'
    util.write(bf, rv.body)
    vim.list_extend(args, { '--body-file', bf })
    files[#files + 1] = bf
  end
  if #comments > 0 then
    local cf = vim.fn.tempname() .. '.json'
    util.write(cf, vim.json.encode(comments))
    vim.list_extend(args, { '--comments-file', cf })
    files[#files + 1] = cf
  end
  if rv.commit and rv.commit ~= '' then
    vim.list_extend(args, { '--commit', rv.commit })
  end
  local r = forge(root, args)
  for _, f in ipairs(files) do
    os.remove(f)
  end
  return r.code == 0, util.trim(r.stderr ~= '' and r.stderr or r.stdout)
end

return M
