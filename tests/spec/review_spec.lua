local h = require 'tests.helpers'
local agent = require 'redline.agent'
local config = require 'redline.config'
local inline = require 'redline.inline'
local review = require 'redline.review'
local snapshot = require 'redline.snapshot'

local PANE = { pane_id = 'w9:p1', agent = 'claude', agent_status = 'idle', cwd = '/x', title = 't', workspace_id = 'w9', in_repo = true }

local function texts(buf, ns)
  local res = {}
  for _, m in ipairs(h.marks(buf, ns)) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local s = ''
      for _, ch in ipairs(vl) do
        s = s .. ch[1]
      end
      res[#res + 1] = { row = m[2], text = vim.trim(s) }
    end
  end
  return res
end

describe('review', function()
  before_each(function()
    config.setup { diff = { interval = 0 }, state_dir = vim.fn.tempname() }
    review.dbs = {}
    review.marks = {}
    require('redline.pr').state = nil
    inline.disable()
    agent.target = nil
    h.wipe()
    h.fake_reset()
  end)

  it('formats comments as one prompt', function()
    local text = review.format {
      { id = 1, path = 'lua/a.lua', l1 = 3, l2 = 5, text = 'Rename this.', code = { 'local x = 1', 'local y = 2', 'return x' }, ft = 'lua', created = 0 },
      { id = 2, path = 'b.py', l1 = 7, l2 = 7, text = 'Handle None.\nAlso log it.', code = { 'f(x)' }, ft = 'python', created = 0 },
    }
    eq(
      table.concat({
        'I reviewed the code and left 2 comment(s). Please address each one.',
        '',
        '## 1. lua/a.lua:3-5',
        '',
        '```lua',
        'local x = 1',
        'local y = 2',
        'return x',
        '```',
        '',
        'Rename this.',
        '',
        '## 2. b.py:7',
        '',
        '```python',
        'f(x)',
        '```',
        '',
        'Handle None.',
        'Also log it.',
        '',
      }, '\n'),
      text
    )
  end)

  it('shows comments as virtual lines, tracks edits and persists across restarts', function()
    local dir = h.repo { ['a.lua'] = '1\n2\n3\n4\n' }
    local buf = h.open(dir, 'a.lua')
    ok(review.add { buf = buf, l1 = 2, l2 = 3, text = 'Fix this' })
    eq({ { row = 2, text = '▍ #1 L2-3 Fix this' } }, texts(buf, review.ns))

    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'new', 'lines' })
    review.sync(dir)
    local c = review.db(dir).comments[1]
    eq({ 4, 5 }, { c.l1, c.l2 })

    review.dbs = {}
    local again = review.db(dir).comments
    eq(1, #again)
    eq({ 'Fix this', 4, 5, { '2', '3' } }, { again[1].text, again[1].l1, again[1].l2, again[1].code })
    ok(vim.uv.fs_stat(review.file(dir)))
  end)

  it('finds, edits and deletes the comment under the cursor', function()
    local dir = h.repo { ['a.lua'] = '1\n2\n3\n' }
    local buf = h.open(dir, 'a.lua')
    review.add { buf = buf, l1 = 1, l2 = 3, text = 'outer' }
    review.add { buf = buf, l1 = 2, l2 = 2, text = 'inner' }
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq('inner', review.at_cursor().text)
    review.delete()
    eq(
      { 'outer' },
      vim.tbl_map(function(c)
        return c.text
      end, review.db(dir).comments)
    )
    eq(1, #texts(buf, review.ns))
  end)

  it('adds and edits comments in a floating editor', function()
    local dir = h.repo { ['a.lua'] = '1\n2\n' }
    local buf = h.open(dir, 'a.lua')
    local win = vim.api.nvim_get_current_win()
    vim.keymap.set('x', '<F4>', review.add)
    vim.api.nvim_feedkeys(vim.keycode 'ggVj<F4>first line<CR>second<C-s>', 'x', false)
    eq(win, vim.api.nvim_get_current_win())
    local c = review.db(dir).comments[1]
    eq({ 1, 2, 'first line\nsecond' }, { c.l1, c.l2, c.text })
    eq(2, #texts(buf, review.ns))

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    review.edit()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
    vim.api.nvim_feedkeys(vim.keycode '<CR>', 'x', false)
    eq('changed', review.db(dir).comments[1].text)
    eq('▍ #1 L1-2 changed', texts(buf, review.ns)[1].text)
  end)

  it('lists comments in quickfix', function()
    local dir = h.repo { ['a.lua'] = '1\n2\n', ['b.lua'] = 'x\n' }
    review.add { buf = h.open(dir, 'b.lua'), l1 = 1, text = 'B' }
    review.add { buf = h.open(dir, 'a.lua'), l1 = 2, text = 'A' }
    review.list(dir)
    local items = vim.fn.getqflist()
    eq(2, #items)
    eq('#1 [pending] B', items[1].text)
    vim.cmd.cclose()
  end)

  it('snapshots, sends all comments as one prompt and checks them afterwards', function()
    local dir = h.repo { ['a.lua'] = 'one\ntwo\nthree\nfour\n', ['b.lua'] = 'x\ny\n' }
    review.add { buf = h.open(dir, 'b.lua'), l1 = 2, text = 'Second file' }
    review.add { buf = h.open(dir, 'a.lua'), l1 = 2, l2 = 3, text = 'Rework' }
    review.add { buf = vim.api.nvim_get_current_buf(), l1 = 4, text = 'Keep' }
    agent.target = { kind = 'herdr', pane = PANE }

    ok(review.send { root = dir, submit = true })
    local calls = h.calls 'herdr'
    local prompt = vim.tbl_filter(function(c)
      return c.argv[2] == 'agent' and c.argv[3] == 'prompt'
    end, calls)
    eq(1, #prompt)
    eq('w9:p1', prompt[1].argv[4])
    local text = prompt[1].argv[5]
    ok(text:find('left 3 comment', 1, true), text)
    ok(text:find('## 1. a.lua:2-3\n\n```lua\ntwo\nthree\n```\n\nRework', 1, true), text)
    ok(text:find('## 3. b.lua:2', 1, true), text)

    local snaps = snapshot.list(dir)
    eq(1, #snaps)
    eq('review: 3 comment(s)', snaps[1].label)
    for _, c in ipairs(review.db(dir).comments) do
      eq(snaps[1].sha, c.snapshot.sha)
      ok(c.sent)
    end
    eq(0, #review.pending(dir))

    -- The agent addresses one comment and inserts a line above everything.
    h.write(dir, { ['a.lua'] = 'header\none\nTWO\nthree\nfour\n' })
    vim.cmd 'silent! checktime'
    vim.cmd 'silent! edit!'
    local st = {}
    for _, s in ipairs(review.status(dir, snaps[1].sha)) do
      st[s.c.text] = { s.l1, s.l2, s.touched }
    end
    eq({ Rework = { 3, 4, true }, Keep = { 5, 5, false }, ['Second file'] = { 2, 2, false } }, st)

    review.check()
    ok(inline.active())
    local qf = vim.tbl_map(function(i)
      return i.text
    end, vim.fn.getqflist())
    table.sort(qf)
    eq({ '#1 [UNTOUCHED] Second file', '#2 [touched] Rework', '#3 [UNTOUCHED] Keep' }, qf)
    local shown = texts(vim.api.nvim_get_current_buf(), review.check_ns)
    eq({ { row = 3, text = '▍ ✓ touched #2 L2-3 Rework' }, { row = 4, text = '▍ ✗ untouched #3 L4 Keep' } }, shown)
  end)

  it('does not mark comments sent when sending fails', function()
    local dir = h.repo { ['a.lua'] = '1\n' }
    review.add { buf = h.open(dir, 'a.lua'), l1 = 1, text = 'x' }
    agent.target = { kind = 'herdr', pane = PANE }
    h.reply('herdr', 'agent prompt*', '', 1)
    review.send { root = dir, submit = true }
    eq(1, #review.pending(dir))
  end)
end)
