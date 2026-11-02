local h = require 'tests.helpers'
local config = require 'redline.config'
local diff = require 'redline.diff'
local render = require 'redline.render'
local inline = require 'redline.inline'

---@param buf integer
---@return {adds: integer[], virt: {row: integer, above: boolean, lines: string[]}[], words: {row: integer, s: integer, e: integer}[]}
local function summary(buf)
  local res = { adds = {}, virt = {}, words = {} }
  for _, m in ipairs(h.marks(buf, render.ns)) do
    local row, col, d = m[2], m[3], m[4]
    if d.line_hl_group == 'RedlineAdd' then
      res.adds[#res.adds + 1] = row
    end
    if d.hl_group == 'RedlineAddText' then
      res.words[#res.words + 1] = { row = row, s = col, e = d.end_col }
    end
    if d.virt_lines then
      local lines = {}
      for _, vl in ipairs(d.virt_lines) do
        local s = ''
        for _, ch in ipairs(vl) do
          s = s .. ch[1]
        end
        lines[#lines + 1] = vim.trim(s)
      end
      res.virt[#res.virt + 1] = { row = row, above = d.virt_lines_above or false, lines = lines }
    end
  end
  return res
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe('diff', function()
  before_each(function()
    config.setup { diff = { interval = 0, syntax = false } }
    inline.disable()
    h.wipe()
  end)

  it('computes hunks', function()
    local hs = diff.hunks({ 'a', 'b', 'c', 'd' }, { 'a', 'B', 'c', 'd', 'e' })
    eq(2, #hs)
    eq({ old_start = 2, old_count = 1, new_start = 2, new_count = 1, old_lines = { 'b' } }, hs[1])
    eq({ old_start = 4, old_count = 0, new_start = 5, new_count = 1, old_lines = {} }, hs[2])
  end)

  it('maps a change to a green line and a red virtual line above it', function()
    local new = { 'local a = 1', 'local y = 2', 'return a' }
    local buf = scratch(new)
    render.draw(buf, diff.hunks({ 'local a = 1', 'local x = 2', 'return a' }, new), { width = 20 })
    local s = summary(buf)
    eq({ 1 }, s.adds)
    eq({ { row = 1, above = true, lines = { 'local x = 2' } } }, s.virt)
    eq({ { row = 1, s = 6, e = 7 } }, s.words)
  end)

  it('places pure deletions below the previous line, or above the first', function()
    local buf = scratch { 'a', 'c' }
    render.draw(buf, diff.hunks({ 'a', 'b', 'c' }, { 'a', 'c' }))
    eq({ { row = 0, above = false, lines = { 'b' } } }, summary(buf).virt)
    eq({}, summary(buf).adds)

    buf = scratch { 'b' }
    render.draw(buf, diff.hunks({ 'a', 'b' }, { 'b' }))
    eq({ { row = 0, above = true, lines = { 'a' } } }, summary(buf).virt)
  end)

  it('marks pure additions without virtual lines', function()
    local buf = scratch { 'a', 'x', 'y', 'b' }
    render.draw(buf, diff.hunks({ 'a', 'b' }, { 'a', 'x', 'y', 'b' }))
    eq({ 1, 2 }, summary(buf).adds)
    eq({}, summary(buf).virt)
  end)

  it('pads virtual lines to the window width and expands tabs', function()
    local ch = render.chunks('\tx', {}, 'RedlineDelete', 10, 4)
    local s = ''
    for _, c in ipairs(ch) do
      s = s .. c[1]
    end
    eq('    x     ', s)
  end)

  it('highlights removed lines with treesitter when available', function()
    local spans = render.syntax('local x = 1', 'lua', { [0] = true })
    if not spans[0] then
      return -- no lua parser in this nvim build
    end
    local ch = render.chunks('local x = 1', spans[0], 'RedlineDelete', 0, 8)
    eq('RedlineDelete', ch[1][2][1])
    ok(ch[1][2][2] and ch[1][2][2]:find '^@', vim.inspect(ch[1]))
  end)

  it('maps old ranges and tells touched from untouched', function()
    local hs = diff.hunks({ '1', '2', '3', '4', '5', '6', '7', '8' }, { '0', '1', '2', '3x', '4', '5', '7', '8', '9' })
    eq({ l1 = 2, l2 = 3, touched = true }, diff.map_range(hs, 1, 2), 'insertion right before')
    eq({ l1 = 4, l2 = 4, touched = true }, diff.map_range(hs, 3, 3), 'changed')
    eq({ l1 = 5, l2 = 5, touched = false }, diff.map_range(hs, 4, 4), 'shifted only')
    eq({ l1 = 7, l2 = 7, touched = false }, diff.map_range(hs, 7, 7), 'shifted after a deletion')
    eq({ l1 = 6, l2 = 6, touched = true }, diff.map_range(hs, 6, 6), 'deleted: line above the gap')
    eq({ l1 = 8, l2 = 8, touched = true }, diff.map_range(hs, 8, 8), 'appended after')
  end)
end)

describe('inline', function()
  before_each(function()
    config.setup { diff = { interval = 0, syntax = false, debounce = 10 } }
    inline.disable()
    h.wipe()
  end)

  it('diffs every changed file against a rev and lists hunks in quickfix', function()
    local dir = h.repo { ['a.lua'] = 'one\ntwo\nthree\n', ['b.lua'] = 'x\ny\n', ['gone.txt'] = 'bye\n' }
    h.write(dir, { ['a.lua'] = 'one\nTWO\nthree\n', ['b.lua'] = 'x\ny\nz\n', ['new.txt'] = 'hi\n' })
    os.remove(dir .. '/gone.txt')
    local buf = h.open(dir, 'a.lua')
    ok(inline.enable { root = dir, rev = 'HEAD' })
    local s = summary(buf)
    eq({ 1 }, s.adds)
    eq('two', s.virt[1].lines[1])

    local qf = vim.fn.getqflist { title = 1, items = 1 }
    eq('redline diff', qf.title)
    local got = vim.tbl_map(function(it)
      return vim.fs.basename(vim.api.nvim_buf_get_name(it.bufnr)) .. ':' .. it.lnum .. ' ' .. it.text
    end, qf.items)
    eq({ 'a.lua:2 M +1 -1', 'b.lua:3 M +1 -0', 'gone.txt:1 deleted', 'new.txt:1 A +1 -0' }, got)
  end)

  it('jumps to the next and previous hunk across files', function()
    local dir = h.repo { ['a.lua'] = '1\n2\n3\n4\n5\n', ['b.lua'] = 'x\ny\n' }
    h.write(dir, { ['a.lua'] = '1\nX\n3\n4\nY\n', ['b.lua'] = 'x\nZ\n' })
    h.open(dir, 'a.lua')
    ok(inline.enable { root = dir, rev = 'HEAD' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    inline.nav(1)
    eq(2, vim.fn.line '.')
    inline.nav(1)
    eq(5, vim.fn.line '.')
    inline.nav(1)
    eq('b.lua', vim.fs.basename(vim.api.nvim_buf_get_name(0)))
    eq(2, vim.fn.line '.')
    inline.nav(-1)
    eq('a.lua', vim.fs.basename(vim.api.nvim_buf_get_name(0)))
    eq(5, vim.fn.line '.')
  end)

  it('updates live on edits and on files changed by an agent', function()
    local dir = h.repo { ['a.lua'] = 'a\nb\nc\n' }
    local buf = h.open(dir, 'a.lua')
    ok(inline.enable { root = dir, rev = 'HEAD' })
    eq({}, summary(buf).adds)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'A' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    ok(
      vim.wait(1000, function()
        return #summary(buf).adds == 1
      end),
      'redraw after edit'
    )
    vim.cmd 'silent! write'

    vim.uv.sleep(1100) -- mtime granularity
    h.write(dir, { ['a.lua'] = 'A\nb\nc\nd\n' })
    vim.cmd.checktime()
    ok(
      vim.wait(1000, function()
        return #summary(buf).adds == 2
      end),
      'redraw after checktime: ' .. vim.inspect(summary(buf))
    )
    eq('d', vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1])
  end)

  it('turns off cleanly', function()
    local dir = h.repo { ['a.lua'] = 'a\n' }
    h.write(dir, { ['a.lua'] = 'b\n' })
    local buf = h.open(dir, 'a.lua')
    ok(inline.enable { root = dir, rev = 'HEAD' })
    ok(#h.marks(buf, render.ns) > 0)
    inline.toggle()
    eq(false, inline.active())
    eq(0, #h.marks(buf, render.ns))
  end)
end)
