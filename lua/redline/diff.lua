local M = {}

---@class redline.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]

local textdiff = vim.text and vim.text.diff or vim.diff

---@param lines string[]
---@return string
local function join(lines)
  return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
end

---@param old string[]
---@param new string[]
---@return redline.Hunk[]
function M.hunks(old, new)
  local idx = textdiff(join(old), join(new), { result_type = 'indices', algorithm = 'histogram' }) --[[@as integer[][] ]]
  local res = {}
  for _, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    res[#res + 1] = {
      old_start = sa,
      old_count = ca,
      new_start = sb,
      new_count = cb,
      old_lines = vim.list_slice(old, sa, sa + ca - 1),
    }
  end
  return res
end

---@param s string
---@return string[] tokens, integer[] offsets 0-based byte starts
local function tokens(s)
  local t, o = {}, {}
  local i = 1
  while i <= #s do
    local _, e = s:find('^[%w_]+', i)
    if not e then
      _, e = s:find('^%s+', i)
    end
    if not e then
      e = i + #(s:sub(i):match '^[%z\1-\127\194-\244][\128-\191]*' or 'x') - 1
    end
    t[#t + 1] = s:sub(i, e)
    o[#o + 1] = i - 1
    i = e + 1
  end
  return t, o
end

---@alias redline.Range {[1]: integer, [2]: integer} 0-based start, exclusive end

--- Changed byte ranges between two versions of a line.
---@param a string
---@param b string
---@return redline.Range[] old, redline.Range[] new
function M.words(a, b)
  local ta, oa = tokens(a)
  local tb, ob = tokens(b)
  if #ta == 0 or #tb == 0 then
    return {}, {}
  end
  local idx = textdiff(join(ta), join(tb), { result_type = 'indices' }) --[[@as integer[][] ]]
  local ra, rb = {}, {}
  local changed = 0
  for _, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      ra[#ra + 1] = { oa[sa], oa[sa + ca - 1] + #ta[sa + ca - 1] }
    end
    if cb > 0 then
      rb[#rb + 1] = { ob[sb], ob[sb + cb - 1] + #tb[sb + cb - 1] }
      changed = changed + cb
    end
  end
  -- A fully rewritten line reads better as a plain line highlight.
  if changed >= #tb and #idx == 1 then
    return {}, {}
  end
  return ra, rb
end

--- Maps a line of the old side to the new side.
---@param hunks redline.Hunk[]
---@param l integer
---@return integer line, boolean inside
function M.map_line(hunks, l)
  local delta = 0
  for _, h in ipairs(hunks) do
    if h.old_count == 0 then
      if h.old_start < l then
        delta = delta + h.new_count
      else
        break
      end
    else
      local oe = h.old_start + h.old_count - 1
      if oe < l then
        delta = delta + h.new_count - h.old_count
      elseif h.old_start <= l then
        local off = math.min(l - h.old_start, math.max(h.new_count - 1, 0))
        return math.max(h.new_start + off, 1), true
      else
        break
      end
    end
  end
  return math.max(l + delta, 1), false
end

---@class redline.Mapped
---@field l1 integer
---@field l2 integer
---@field touched boolean

--- Maps an old-side range and reports whether any hunk touches it,
--- counting insertions directly before or after the range.
---@param hunks redline.Hunk[]
---@param l1 integer
---@param l2 integer
---@return redline.Mapped
function M.map_range(hunks, l1, l2)
  local a = M.map_line(hunks, l1)
  local b = M.map_line(hunks, l2)
  local touched = false
  for _, h in ipairs(hunks) do
    if h.old_count == 0 then
      if h.old_start >= l1 - 1 and h.old_start <= l2 then
        touched = true
      end
    elseif h.old_start <= l2 and h.old_start + h.old_count - 1 >= l1 then
      touched = true
    end
  end
  return { l1 = a, l2 = math.max(a, b), touched = touched }
end

return M
