local config = require 'redline.config'
local diff = require 'redline.diff'
local git = require 'redline.git'
local util = require 'redline.util'

---@class redline.PR
---@field number integer
---@field title string
---@field author string
---@field head string
---@field head_sha string
---@field base string
---@field url string

---@class redline.PrComment
---@field path string
---@field line integer
---@field start_line? integer
---@field side 'new'|'old'
---@field author string
---@field body string
---@field outdated? boolean

---@class redline.ReviewSubmit
---@field event 'approve'|'request_changes'|'comment'
---@field body string
---@field comments redline.Comment[]
---@field commit? string

---@class redline.Backend
---@field name string
---@field list fun(root: string): redline.PR[]?, string?
---@field checkout fun(root: string, n: integer): boolean, string?
---@field comments fun(root: string, n: integer): redline.PrComment[]?, string?
---@field submit fun(root: string, n: integer, rv: redline.ReviewSubmit): boolean, string?

---@class redline.PrState
---@field root string
---@field backend string
---@field number integer
---@field pr redline.PR
---@field base string
---@field comments redline.PrComment[]

local M = {}

---@type redline.PrState?
M.state = nil

M.ns = vim.api.nvim_create_namespace 'redline.pr'

---@param root string
---@return redline.Backend
function M.backend(root)
  local name = config.options.pr.backend
  if not name then
    local url = git.ok(root, { 'remote', 'get-url', config.options.pr.remote }) or ''
    name = url:find('github.com', 1, true) and 'gh' or 'forge'
  end
  return require('redline.pr.' .. name)
end

---@param pr redline.PR
---@return string
local function fmt(pr)
  return string.format('#%d %s  (%s → %s, @%s)', pr.number, pr.title, pr.head, pr.base, pr.author)
end

---@param root string
---@param base string
---@return string?
local function merge_base(root, base)
  local remote = config.options.pr.remote
  git.run(root, { 'fetch', '--quiet', remote, base })
  for _, ref in ipairs { remote .. '/' .. base, base } do
    if git.sha(root, ref) then
      local mb = git.ok(root, { 'merge-base', 'HEAD', ref })
      if mb then
        return mb
      end
    end
  end
end

---@param c redline.PrComment
---@return [string, string][][]
local function virt(c)
  local out = {}
  local head = string.format(' @%s%s: ', c.author, c.outdated and ' (outdated)' or '')
  for i, line in ipairs(vim.split(c.body, '\n', { plain = true })) do
    out[#out + 1] = {
      { ' ▍', 'RedlineCommentSign' },
      { (i == 1 and head or string.rep(' ', #head)) .. line .. string.rep(' ', math.max(vim.o.columns - #line - #head - 4, 1)), 'RedlinePrComment' },
    }
  end
  return out
end

local overlay = {
  ---@param buf integer
  ---@param rel string
  ---@param hunks redline.Hunk[]
  draw = function(buf, rel, hunks)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    local s = M.state
    if not s then
      return
    end
    local n = vim.api.nvim_buf_line_count(buf)
    for _, c in ipairs(s.comments) do
      if c.path == rel then
        local line = c.side == 'new' and c.line or diff.map_line(hunks, c.line)
        vim.api.nvim_buf_set_extmark(buf, M.ns, math.min(line, n) - 1, 0, { virt_lines = virt(c), priority = 250 })
      end
    end
  end,
  clear = function(buf)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
  end,
}

--- Checks out the PR head (refusing on a dirty tree), then shows the diff
--- against the merge-base with existing comments.
---@param root string
---@param be redline.Backend
---@param pr redline.PR
---@return boolean
function M.start(root, be, pr)
  local head = git.sha(root, 'HEAD')
  if pr.head_sha == '' or head ~= pr.head_sha then
    if git.dirty(root) then
      util.err(
        string.format(
          'Working tree has changes; not checking out PR #%d. Use a worktree:\n  git worktree add ../%s-pr%d && cd ../%s-pr%d',
          pr.number,
          vim.fs.basename(root),
          pr.number,
          vim.fs.basename(root),
          pr.number
        )
      )
      return false
    end
    local ok, err = be.checkout(root, pr.number)
    if not ok then
      util.err('Checkout failed: ' .. (err or ''))
      return false
    end
  end
  local mb = merge_base(root, pr.base)
  if not mb then
    util.err('No merge-base with ' .. pr.base)
    return false
  end
  local comments, err = be.comments(root, pr.number)
  if not comments then
    util.warn('Could not load review comments: ' .. (err or ''))
  end
  M.state = { root = root, backend = be.name, number = pr.number, pr = pr, base = mb, comments = comments or {} }
  local inline = require 'redline.inline'
  if not inline.enable { root = root, rev = mb, label = string.format('PR #%d (merge-base %s)', pr.number, pr.base) } then
    M.state = nil
    return false
  end
  inline.overlay('pr', overlay)
  require('redline.review').redraw(root)
  return true
end

---@param n? integer
function M.open(n)
  local root = git.root()
  if not root then
    return util.err 'Not in a git repository'
  end
  local be = M.backend(root)
  local prs, err = be.list(root)
  if not prs then
    return util.err(be.name .. ' pr list failed: ' .. (err or ''))
  end
  if n then
    for _, p in ipairs(prs) do
      if p.number == n then
        return M.start(root, be, p)
      end
    end
    return util.err('PR #' .. n .. ' not found')
  end
  if #prs == 0 then
    return util.notify 'No open pull requests'
  end
  vim.ui.select(prs, { prompt = 'Pull request (' .. be.name .. ')', format_item = fmt }, function(p)
    if p then
      M.start(root, be, p)
    end
  end)
end

---@param opts? {event?: string, body?: string}
function M.submit(opts)
  opts = opts or {}
  local s = M.state
  if not s then
    return util.warn 'No PR review in progress (:Redline pr)'
  end
  local review = require 'redline.review'
  local function go(event, body)
    local comments = review.pending(s.root, s.number)
    local ok, err = M.backend(s.root).submit(s.root, s.number, {
      event = event,
      body = body,
      comments = comments,
      commit = s.pr.head_sha ~= '' and s.pr.head_sha or git.sha(s.root, 'HEAD'),
    })
    if not ok then
      return util.err('Submit failed: ' .. (err or ''))
    end
    review.remove(
      s.root,
      vim.tbl_map(function(c)
        return c.id
      end, comments)
    )
    review.redraw(s.root)
    util.notify(string.format('Submitted %s on PR #%d with %d comment(s)', event, s.number, #comments))
  end
  if opts.event then
    return go(opts.event, opts.body or '')
  end
  vim.ui.select({ 'comment', 'approve', 'request_changes' }, { prompt = 'Review event' }, function(ev)
    if not ev then
      return
    end
    vim.ui.input({ prompt = 'Review body: ' }, function(body)
      if body then
        go(ev, body)
      end
    end)
  end)
end

function M.close()
  local s = M.state
  M.state = nil
  require('redline.inline').disable()
  if s then
    require('redline.review').redraw(s.root)
  end
end

return M
