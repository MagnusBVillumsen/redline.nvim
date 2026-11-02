local h = require 'tests.helpers'
local agent = require 'redline.agent'
local config = require 'redline.config'
local herdr = require 'redline.herdr'
local term = require 'redline.terminal'

local function agents_json(root)
  return vim.json.encode {
    id = 'cli:agent:list',
    result = {
      agents = {
        { pane_id = 'w1:p1', agent = 'codex', agent_status = 'idle', cwd = '/elsewhere', terminal_title_stripped = 'other', workspace_id = 'w1' },
        { pane_id = 'w1:p2', agent = 'claude', agent_status = 'working', cwd = root .. '/sub', terminal_title_stripped = 'mine', workspace_id = 'w1' },
        { pane_id = 'w1:p3', agent = 'pi', agent_status = 'idle', cwd = root .. '-other', terminal_title_stripped = 'prefix only', workspace_id = 'w1' },
      },
    },
  }
end

---@param name string
local function herdr_calls(name)
  return vim.tbl_filter(function(c)
    return c.argv[2] .. ' ' .. c.argv[3] == name
  end, h.calls 'herdr')
end

describe('herdr', function()
  before_each(function()
    config.setup()
    agent.target = nil
    h.wipe()
    h.fake_reset()
  end)

  it('uses $HERDR_BIN_PATH, then the config', function()
    eq(TEST_BIN .. '/herdr', herdr.bin())
    config.setup { agent = { herdr = { bin = '/opt/herdr' } } }
    eq('/opt/herdr', herdr.bin())
  end)

  it('lists agent panes with the ones in the repo first', function()
    local root = h.repo()
    h.reply('herdr', 'agent list', agents_json(root))
    local list = herdr.list(root)
    eq(
      { 'w1:p2', 'w1:p1', 'w1:p3' },
      vim.tbl_map(function(p)
        return p.pane_id
      end, list)
    )
    eq(
      { true, false, false },
      vim.tbl_map(function(p)
        return p.in_repo
      end, list)
    )
    eq('mine', list[1].title)
  end)

  it('sends a visual selection with metadata wrapped in bracketed paste, without submitting', function()
    local root = h.repo { ['lua/foo.lua'] = 'local a = 1\nlocal b = 2\n' }
    h.open(root, 'lua/foo.lua')
    h.reply('herdr', 'agent list', agents_json(root))
    agent.target = { kind = 'herdr', pane = herdr.list(root)[1] }
    vim.keymap.set('x', '<F3>', agent.send_selection)
    vim.api.nvim_feedkeys(vim.keycode 'ggVj<F3>', 'x', false)
    local sends = herdr_calls 'pane send-text'
    eq(1, #sends)
    eq({ 'herdr', 'pane', 'send-text', 'w1:p2', '\27[200~lua/foo.lua:1-2:\n```lua\nlocal a = 1\nlocal b = 2\n```\n\27[201~' }, sends[1].argv)
    eq(0, #herdr_calls 'agent prompt')
    eq(1, #herdr_calls 'agent focus')
  end)

  it('prefixes text that starts with a dash', function()
    config.setup { agent = { herdr = { bracketed = false } } }
    herdr.send('w1:p2', '-n flag\nnext')
    herdr.prompt('w1:p2', '--help me')
    eq(' -n flag next', herdr_calls('pane send-text')[1].argv[5])
    eq(' --help me', herdr_calls('agent prompt')[1].argv[5])
  end)

  it('sends prompts from the picker with placeholders expanded', function()
    local root = h.repo { ['a.lua'] = 'x = 1\n' }
    h.open(root, 'a.lua')
    agent.target = { kind = 'herdr', pane = { pane_id = 'w1:p2' } }
    agent.prompt 'line'
    local text = herdr_calls('pane send-text')[1].argv[5]
    eq('\27[200~Explain what the code around my cursor does. Do not suggest edits unless I ask.\n\na.lua:1:\n```lua\nx = 1\n```\27[201~', text)
  end)

  it('asks for a target when none is attached', function()
    local root = h.repo()
    h.reply('herdr', 'agent list', agents_json(root))
    vim.cmd.cd(root)
    local orig = vim.ui.select
    local seen
    vim.ui.select = function(items, _, cb)
      seen = vim.tbl_map(function(i)
        return i.label
      end, items)
      cb(items[1])
    end
    agent.send('hello', { focus = false })
    vim.ui.select = orig
    ok(vim.wait(500, function()
      return #herdr_calls 'pane send-text' == 1
    end))
    ok(seen[1]:find('claude', 1, true) and seen[1]:find('★', 1, true), vim.inspect(seen))
    eq('w1:p2', agent.target.pane.pane_id)
  end)
end)

describe('terminal', function()
  before_each(function()
    h.wipe()
    for name, s in pairs(term.sessions) do
      pcall(vim.fn.jobstop, s.chan)
      term.sessions[name] = nil
    end
  end)

  it('spawns a tool in a split, toggles it and pastes with bracketed paste', function()
    local out = vim.fn.tempname()
    local script = string.format("stty raw -echo; echo ready; cat > '%s'", out)
    config.setup { agent = { tools = { dump = { cmd = { 'sh', '-c', script } } }, submit_delay = 10 } }
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    agent.toggle { name = 'dump', focus = false }
    local s = ok(term.sessions.dump)
    eq(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    ok(
      vim.wait(3000, function()
        return table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n'):find 'ready' ~= nil
      end),
      'terminal ready'
    )

    agent.send('one\ntwo', { submit = false, focus = false })
    agent.send('go', { submit = true, focus = false })
    ok(
      vim.wait(3000, function()
        local got = require('redline.util').read(out) or ''
        return got:find('\r', 1, true) ~= nil
      end),
      'received'
    )
    eq('\27[200~one\ntwo\27[201~\27[200~go\27[201~\r', require('redline.util').read(out))

    agent.toggle()
    eq(nil, term.win(s))
    agent.toggle()
    ok(term.win(s))
    vim.fn.jobstop(s.chan)
  end)
end)
