local config = require 'redline.config'
local util = require 'redline.util'

---@type redline.Backend
local M = { name = 'gh' }

---@param root string
---@param args string[]
---@return redline.Result
local function gh(root, args)
  local cmd = { config.options.pr.gh }
  vim.list_extend(cmd, args)
  return util.run(cmd, { cwd = root })
end

function M.list(root)
  local r = gh(root, { 'pr', 'list', '--json', 'number,title,author,headRefName,headRefOid,baseRefName,url' })
  if r.code ~= 0 then
    return nil, util.trim(r.stderr)
  end
  local res = {}
  for _, p in ipairs(util.json(r.stdout) or {}) do
    res[#res + 1] = {
      number = p.number,
      title = p.title or '',
      author = p.author and p.author.login or '',
      head = p.headRefName or '',
      head_sha = p.headRefOid or '',
      base = p.baseRefName or '',
      url = p.url or '',
    }
  end
  return res
end

function M.checkout(root, n)
  local r = gh(root, { 'pr', 'checkout', tostring(n) })
  return r.code == 0, util.trim(r.stderr)
end

function M.comments(root, n)
  local r = gh(root, { 'api', '--paginate', 'repos/{owner}/{repo}/pulls/' .. n .. '/comments' })
  if r.code ~= 0 then
    return nil, util.trim(r.stderr)
  end
  -- --paginate concatenates JSON arrays; join them into one.
  local text = r.stdout:gsub('%]%s*%[', ',')
  local res = {}
  for _, c in ipairs(util.json(text) or {}) do
    local line = c.line or c.original_line
    if line and c.path then
      res[#res + 1] = {
        path = c.path,
        line = line,
        start_line = c.start_line or c.original_start_line,
        side = c.side == 'LEFT' and 'old' or 'new',
        author = c.user and c.user.login or '?',
        body = c.body or '',
        outdated = c.line == nil,
      }
    end
  end
  return res
end

local events = { approve = 'APPROVE', request_changes = 'REQUEST_CHANGES', comment = 'COMMENT' }

function M.submit(root, n, rv)
  local comments = {}
  for _, c in ipairs(rv.comments) do
    local x = { path = c.path, body = c.text, line = c.l2, side = 'RIGHT' }
    if c.l1 < c.l2 then
      x.start_line, x.start_side = c.l1, 'RIGHT'
    end
    comments[#comments + 1] = x
  end
  local payload = { event = events[rv.event], body = rv.body, commit_id = rv.commit }
  if #comments > 0 then
    payload.comments = comments
  end
  local f = vim.fn.tempname() .. '.json'
  util.write(f, vim.json.encode(payload))
  local r = gh(root, { 'api', '-X', 'POST', 'repos/{owner}/{repo}/pulls/' .. n .. '/reviews', '--input', f })
  os.remove(f)
  return r.code == 0, util.trim(r.stderr ~= '' and r.stderr or r.stdout)
end

return M
