local git = require 'redline.git'
local util = require 'redline.util'

local M = {}

---@class redline.Selection
---@field l1 integer
---@field l2 integer
---@field text string
---@field mode string

---@class redline.Context
---@field buf integer
---@field path string Repo-relative path, or the absolute/buffer name outside a repo
---@field root? string
---@field ft string
---@field row integer 1-based
---@field col integer 1-based
---@field sel? redline.Selection

--- Captures the cursor and visual selection. Call this before anything that
--- leaves visual mode; it exits visual mode itself.
---@param buf? integer
---@return redline.Context
function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local root = name ~= '' and git.root(name) or nil
  local path = (root and git.rel(root, name)) or (name ~= '' and vim.fn.fnamemodify(name, ':~:.') or '[No Name]')
  local cur = vim.api.nvim_win_get_cursor(0)
  ---@type redline.Context
  local ctx = { buf = buf, path = path, root = root, ft = vim.bo[buf].filetype, row = cur[1], col = cur[2] + 1 }
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local a, b = vim.fn.getpos 'v', vim.fn.getpos '.'
    local region = vim.fn.getregion(a, b, { type = mode })
    local l1, l2 = math.min(a[2], b[2]), math.max(a[2], b[2])
    ctx.sel = { l1 = l1, l2 = l2, text = table.concat(region, '\n'), mode = mode }
    vim.cmd.normal { vim.keycode '<Esc>', bang = true }
  end
  return ctx
end

--- `path:12-20:` followed by a fenced block with the filetype.
---@param path string
---@param l1 integer
---@param l2 integer
---@param code string
---@param ft string
---@return string
function M.format(path, l1, l2, code, ft)
  return string.format('%s:%s:\n%s\n', path, util.range(l1, l2), util.codeblock(code, ft))
end

---@param ctx redline.Context
---@return string
function M.selection(ctx)
  local sel = ctx.sel
  if not sel then
    return M.line(ctx)
  end
  return M.format(ctx.path, sel.l1, sel.l2, sel.text, ctx.ft)
end

---@param ctx redline.Context
---@return string
function M.line(ctx)
  local text = vim.api.nvim_buf_get_lines(ctx.buf, ctx.row - 1, ctx.row, false)[1] or ''
  return M.format(ctx.path, ctx.row, ctx.row, text, ctx.ft)
end

---@param ctx redline.Context
---@param all boolean
---@return string
function M.diagnostics(ctx, all)
  local l1, l2 = ctx.row, ctx.row
  if ctx.sel then
    l1, l2 = ctx.sel.l1, ctx.sel.l2
  end
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(ctx.buf)) do
    if all or (d.lnum + 1 >= l1 and d.lnum + 1 <= l2) then
      local sev = vim.diagnostic.severity[d.severity] or 'INFO'
      out[#out + 1] = string.format('%s:%d:%d: %s: %s%s', ctx.path, d.lnum + 1, d.col + 1, sev, d.message, d.source and (' (' .. d.source .. ')') or '')
    end
  end
  return #out > 0 and table.concat(out, '\n') or '(no diagnostics)'
end

---@type table<string, fun(ctx: redline.Context): string>
M.vars = {
  selection = M.selection,
  line = M.line,
  file = function(ctx)
    return ctx.path
  end,
  position = function(ctx)
    return string.format('%s:%d:%d', ctx.path, ctx.row, ctx.col)
  end,
  this = function(ctx)
    return ctx.sel and M.selection(ctx) or string.format('%s:%d:%d', ctx.path, ctx.row, ctx.col)
  end,
  diagnostics = function(ctx)
    return M.diagnostics(ctx, false)
  end,
  diagnostics_all = function(ctx)
    return M.diagnostics(ctx, true)
  end,
  buffers = function(ctx)
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if vim.bo[b].buflisted and vim.bo[b].buftype == '' and name ~= '' then
        out[#out + 1] = (ctx.root and git.rel(ctx.root, name)) or vim.fn.fnamemodify(name, ':~:.')
      end
    end
    return table.concat(out, '\n')
  end,
  quickfix = function(ctx)
    local out = {}
    for _, it in ipairs(vim.fn.getqflist()) do
      local name = it.bufnr > 0 and vim.api.nvim_buf_get_name(it.bufnr) or ''
      name = (ctx.root and name ~= '' and git.rel(ctx.root, name)) or name
      out[#out + 1] = string.format('%s:%d: %s', name, it.lnum, util.trim(it.text))
    end
    return table.concat(out, '\n')
  end,
}

--- Expands `{name}` placeholders; unknown names are left as they are.
---@param tpl string
---@param ctx redline.Context
---@return string
function M.render(tpl, ctx)
  local res = tpl:gsub('{([%w_]+)}', function(k)
    local f = M.vars[k]
    if f then
      return (f(ctx):gsub('\n$', ''))
    end
  end)
  return res
end

return M
