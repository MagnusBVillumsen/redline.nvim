local h = require 'tests.helpers'
local config = require 'redline.config'
local inline = require 'redline.inline'
local render = require 'redline.render'
local watch = require 'redline.watch'

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe('watch', function()
  before_each(function()
    inline.disable()
    h.wipe()
    config.setup { diff = { interval = 0 }, watch = { debounce = 20, poll = 0 } }
    watch.setup()
  end)

  it('reloads an unmodified buffer written by another process and keeps the view', function()
    local dir = h.repo { ['a.txt'] = '1\n2\n3\n4\n' }
    local buf = h.open(dir, 'a.txt')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    h.sh("printf '1\\n2\\n3 changed\\n4\\n5\\n' > a.txt", dir)
    ok(
      vim.wait(2000, function()
        return lines(buf)[3] == '3 changed'
      end),
      vim.inspect(lines(buf))
    )
    eq(3, vim.fn.line '.')
    eq(false, vim.bo[buf].modified)
  end)

  it('follows atomic rename writes', function()
    local dir = h.repo { ['b.txt'] = 'old\n' }
    local buf = h.open(dir, 'b.txt')
    for i = 1, 2 do
      h.sh(("printf 'new %d\\n' > .b.txt.tmp && mv .b.txt.tmp b.txt"):format(i), dir)
      ok(
        vim.wait(2000, function()
          return lines(buf)[1] == 'new ' .. i
        end),
        'rename ' .. i .. ': ' .. vim.inspect(lines(buf))
      )
    end
  end)

  it('never overwrites unsaved changes and warns once', function()
    local dir = h.repo { ['c.txt'] = 'disk\n' }
    local buf = h.open(dir, 'c.txt')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'mine' })
    _G.NOTES = {}
    h.sh("printf 'agent\\n' > c.txt", dir)
    ok(
      vim.wait(2000, function()
        return #_G.NOTES > 0
      end),
      'warned'
    )
    watch.check(buf)
    watch.check_all()
    eq({ 'mine' }, lines(buf))
    eq(true, vim.bo[buf].modified)
    eq(1, #_G.NOTES)
    ok(_G.NOTES[1].msg:find('Redline reload!', 1, true))

    vim.cmd 'Redline diskdiff'
    local marks = h.marks(buf, watch.diff_ns)
    ok(#marks > 0)

    vim.cmd 'Redline reload'
    eq({ 'mine' }, lines(buf))
    vim.cmd 'Redline reload!'
    eq({ 'agent' }, lines(buf))
    eq(0, #h.marks(buf, watch.diff_ns))
  end)

  it('cleans up watchers when buffers go away', function()
    local dir = h.repo { ['d.txt'] = 'd\n' }
    local buf = h.open(dir, 'd.txt')
    ok(watch.dirs[dir])
    vim.cmd('bwipeout! ' .. buf)
    eq(nil, watch.dirs[dir])
  end)

  it('caps watchers and falls back to polling', function()
    config.setup { diff = { interval = 0 }, watch = { debounce = 20, max = 0, poll = 50 } }
    watch.setup()
    local dir = h.repo { ['e.txt'] = 'e\n' }
    local buf = h.open(dir, 'e.txt')
    ok(watch.polled[buf])
    h.sh("printf 'polled\\n' > e.txt", dir)
    ok(vim.wait(2000, function()
      return lines(buf)[1] == 'polled'
    end))
    watch.stop()
  end)

  it('drives the live inline diff', function()
    local dir = h.repo { ['f.lua'] = 'a\nb\n' }
    local buf = h.open(dir, 'f.lua')
    ok(inline.enable { root = dir, rev = 'HEAD' })
    h.sh("printf 'a\\nB\\n' > f.lua && printf 'x\\n' > new.lua", dir)
    ok(
      vim.wait(3000, function()
        local adds = 0
        for _, m in ipairs(h.marks(buf, render.ns)) do
          if m[4].line_hl_group == 'RedlineAdd' then
            adds = adds + 1
          end
        end
        return adds == 1 and #inline.state.items == 2
      end),
      vim.inspect { inline.state.items, lines(buf), watch.seen[buf], vim.tbl_keys(watch.dirs), dir, vim.api.nvim_buf_get_name(buf), vim.bo[buf].buflisted }
    )
  end)
end)
