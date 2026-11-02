local config = require 'redline.config'
local diff = require 'redline.diff'
local util = require 'redline.util'

local M = {}

M.ns = vim.api.nvim_create_namespace 'redline.diff'

local function hl(name, dark, light)
  vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', { default = true }, vim.o.background == 'light' and light or dark))
end

function M.highlights()
  hl('RedlineAdd', { bg = '#1d3b26' }, { bg = '#dafbe1' })
  hl('RedlineAddText', { bg = '#2f6b3d' }, { bg = '#aceebb' })
  hl('RedlineAddSign', { fg = '#3fb950' }, { fg = '#1a7f37' })
  hl('RedlineDelete', { bg = '#4a1e24' }, { bg = '#ffebe9' })
  hl('RedlineDeleteText', { bg = '#8a2e38' }, { bg = '#ff9c94' })
  hl('RedlineDeleteSign', { fg = '#f85149' }, { fg = '#cf222e' })
  hl('RedlineComment', { bg = '#1f2b47', fg = '#c8d3f5' }, { bg = '#ddf4ff', fg = '#0a3069' })
  hl('RedlineCommentSign', { fg = '#58a6ff' }, { fg = '#0969da' })
  hl('RedlinePrComment', { bg = '#2b2442', fg = '#d2c6f5' }, { bg = '#fbefff', fg = '#512a97' })
  hl('RedlineTouched', { fg = '#3fb950', bold = true }, { fg = '#1a7f37', bold = true })
  hl('RedlineUntouched', { fg = '#d29922', bold = true }, { fg = '#9a6700', bold = true })
end

---@class redline.Span
---@field s integer 0-based byte start
---@field e integer exclusive end
---@field hl string

--- Treesitter highlight spans for some rows of a text.
---@param text string
---@param lang string
---@param rows table<integer, true> 0-based rows wanted
---@return table<integer, redline.Span[]>
function M.syntax(text, lang, rows)
  local res = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return res
  end
  local qok, query = pcall(vim.treesitter.query.get, lang, 'highlights')
  if not qok or not query then
    return res
  end
  local tok, trees = pcall(parser.parse, parser)
  if not tok or not trees or not trees[1] then
    return res
  end
  local lo, hi = math.huge, -1
  for r in pairs(rows) do
    lo, hi = math.min(lo, r), math.max(hi, r)
  end
  if hi < 0 then
    return res
  end
  for id, node in query:iter_captures(trees[1]:root(), text, lo, hi + 1) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' then
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        if rows[r] then
          local list = res[r] or {}
          res[r] = list
          list[#list + 1] = { s = r == sr and sc or 0, e = r == er and ec or math.huge, hl = '@' .. name .. '.' .. lang }
        end
      end
    end
  end
  return res
end

--- Splits a line into virt_text chunks, stacking syntax and word highlights
--- over the base highlight, with tabs expanded and padded to full width.
---@param line string
---@param spans redline.Span[]
---@param base string
---@param width integer
---@param ts integer tabstop
---@return [string, string[]][]
function M.chunks(line, spans, base, width, ts)
  local cuts = { [0] = true, [#line] = true }
  for _, sp in ipairs(spans) do
    cuts[math.max(0, math.min(sp.s, #line))] = true
    cuts[math.max(0, math.min(sp.e, #line))] = true
  end
  local pts = vim.tbl_keys(cuts)
  table.sort(pts)
  local res = {}
  local col = 0
  for i = 1, #pts - 1 do
    local s, e = pts[i], pts[i + 1]
    local groups = { base }
    for _, sp in ipairs(spans) do
      if sp.s <= s and sp.e >= e then
        groups[#groups + 1] = sp.hl
      end
    end
    local seg = line:sub(s + 1, e)
    local out = {}
    for ch in seg:gmatch '[%z\1-\127\194-\244][\128-\191]*' do
      if ch == '\t' then
        local n = ts - (col % ts)
        out[#out + 1] = string.rep(' ', n)
        col = col + n
      else
        out[#out + 1] = ch
        col = col + vim.fn.strdisplaywidth(ch)
      end
    end
    res[#res + 1] = { table.concat(out), groups }
  end
  if col < width then
    res[#res + 1] = { string.rep(' ', width - col), { base } }
  end
  return res
end

---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

---@class redline.DrawOpts
---@field old? string[] Full old file, for syntax highlighting
---@field width? integer
---@field ns? integer Defaults to the inline diff namespace

---@param buf integer
---@param hunks redline.Hunk[]
---@param opts? redline.DrawOpts
function M.draw(buf, hunks, opts)
  opts = opts or {}
  local o = config.options.diff
  local ns = opts.ns or M.ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  local width = opts.width or vim.o.columns
  local ts = vim.bo[buf].tabstop
  local new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local syn = {}
  if o.syntax and opts.old then
    local rows = {}
    for _, h in ipairs(hunks) do
      for i = 0, h.old_count - 1 do
        rows[h.old_start - 1 + i] = true
      end
    end
    local ft = vim.bo[buf].filetype
    if ft ~= '' and next(rows) then
      syn = M.syntax(table.concat(opts.old, '\n'), util.lang(ft), rows)
    end
  end

  for _, h in ipairs(hunks) do
    local pairs_ = (o.word and h.old_count > 0 and h.new_count > 0) and math.min(h.old_count, h.new_count) or 0
    local words = {}
    for i = 1, pairs_ do
      local a, b = diff.words(h.old_lines[i], new[h.new_start + i - 1] or '')
      words[i] = { a, b }
    end

    for i = 0, h.new_count - 1 do
      local row = h.new_start - 1 + i
      if row < count then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          line_hl_group = 'RedlineAdd',
          sign_text = o.signs and '+' or nil,
          sign_hl_group = o.signs and 'RedlineAddSign' or nil,
          priority = 100,
        })
        local w = words[i + 1]
        for _, r in ipairs(w and w[2] or {}) do
          vim.api.nvim_buf_set_extmark(buf, ns, row, r[1], {
            end_col = math.min(r[2], #(new[row + 1] or '')),
            hl_group = 'RedlineAddText',
            priority = 101,
          })
        end
      end
    end

    if h.old_count > 0 then
      local vl = {}
      for i, line in ipairs(h.old_lines) do
        local spans = vim.deepcopy(syn[h.old_start - 2 + i] or {})
        local w = words[i]
        for _, r in ipairs(w and w[1] or {}) do
          spans[#spans + 1] = { s = r[1], e = r[2], hl = 'RedlineDeleteText' }
        end
        vl[#vl + 1] = M.chunks(line, spans, 'RedlineDelete', width, ts)
      end
      local row, above
      if h.new_count > 0 then
        row, above = h.new_start - 1, true
      elseif h.new_start == 0 then
        row, above = 0, true
      else
        row, above = h.new_start - 1, false
      end
      if row >= count then
        row, above = math.max(count - 1, 0), false
      end
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_lines = vl,
        virt_lines_above = above,
        priority = 100,
      })
    end
  end
end

return M
