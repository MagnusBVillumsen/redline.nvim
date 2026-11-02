local h = require 'tests.helpers'
local config = require 'redline.config'
local context = require 'redline.context'

describe('selection metadata', function()
  before_each(function()
    config.setup()
    h.wipe()
  end)

  it('formats path, line range and a fenced block', function()
    eq('lua/foo.lua:12-20:\n```lua\nlocal x = 1\n```\n', context.format('lua/foo.lua', 12, 20, 'local x = 1', 'lua'))
    eq('a.py:3:\n```python\npass\n```\n', context.format('a.py', 3, 3, 'pass', 'python'))
  end)

  it('uses a longer fence when the code contains backticks', function()
    eq('README.md:1-3:\n````markdown\n```sh\nls\n```\n````\n', context.format('README.md', 1, 3, '```sh\nls\n```', 'markdown'))
  end)

  it('captures a linewise visual selection with a repo-relative path', function()
    local dir = h.repo { ['lua/foo.lua'] = 'local a = 1\nlocal b = 2\nlocal c = 3\n' }
    h.open(dir, 'lua/foo.lua')
    local got
    vim.keymap.set('x', '<F2>', function()
      got = context.selection(context.get())
    end)
    vim.api.nvim_feedkeys(vim.keycode '2GVj<F2>', 'x', false)
    eq('lua/foo.lua:2-3:\n```lua\nlocal b = 2\nlocal c = 3\n```\n', got)
    eq('n', vim.fn.mode())
  end)

  it('captures a charwise selection by its lines', function()
    local dir = h.repo { ['x.lua'] = 'local a = 1\nlocal b = 2\n' }
    h.open(dir, 'x.lua')
    local got
    vim.keymap.set('x', '<F2>', function()
      got = context.selection(context.get())
    end)
    vim.api.nvim_feedkeys(vim.keycode '1G0wvjb<F2>', 'x', false)
    eq('x.lua:1-2:\n```lua\na = 1\nl\n```\n', got)
  end)

  it('expands sidekick-style placeholders', function()
    local dir = h.repo { ['a.lua'] = 'x = 1\ny = 2\n' }
    local buf = h.open(dir, 'a.lua')
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    vim.diagnostic.set(vim.api.nvim_create_namespace 'test', buf, {
      { lnum = 1, col = 0, message = 'bad thing', severity = vim.diagnostic.severity.ERROR, source = 'lint' },
    })
    local ctx = context.get()
    eq('a.lua', context.render('{file}', ctx))
    eq('a.lua:2:3', context.render('{position}', ctx))
    eq('Explain a.lua:2:\n```lua\ny = 2\n```. {unknown}', context.render('Explain {line}. {unknown}', ctx))
    eq('a.lua:2:1: ERROR: bad thing (lint)', context.render('{diagnostics}', ctx))
    eq(
      'Explain a.lua:2:\n```lua\ny = 2\n```. Do not rewrite the code. Focus on helping me understand it.',
      context.render(config.options.agent.prompts.explain, ctx)
    )
  end)

  it('expands {f} and {c} to the enclosing function and class', function()
    local dir = h.repo {
      ['m.lua'] = 'local x = 1\nlocal function add(a, b)\n  return a + b\nend\n',
      ['p.c'] = 'struct point {\n  int x;\n  int y;\n};\n',
    }
    h.open(dir, 'm.lua')
    vim.treesitter.start()
    vim.api.nvim_win_set_cursor(0, { 3, 4 })
    local ctx = context.get()
    local want = 'm.lua:2-4:\n```lua\nlocal function add(a, b)\n  return a + b\nend\n```'
    eq(want, context.render('{f}', ctx))
    eq(want, context.render('{function}', ctx))
    eq('(no class at m.lua:3)', context.render('{c}', ctx))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq('(no function at m.lua:1)', context.render('{f}', context.get()))

    h.open(dir, 'p.c')
    vim.treesitter.start()
    vim.api.nvim_win_set_cursor(0, { 2, 6 })
    eq('p.c:1-4:\n```c\nstruct point {\n  int x;\n  int y;\n};\n```', context.render('{class}', context.get()))
  end)
end)
