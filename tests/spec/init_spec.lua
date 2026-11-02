local h = require 'tests.helpers'

describe('setup', function()
  it('defines the command with completion and the default keymaps', function()
    vim.g.mapleader = ' '
    vim.cmd.runtime 'plugin/redline.lua'
    require('redline').setup { diff = { interval = 0 } }
    eq(2, vim.fn.exists ':Redline')
    local subs = vim.fn.getcompletion('Redline ', 'cmdline')
    for _, s in ipairs { 'toggle', 'send', 'comment', 'review', 'check', 'snapshot', 'diff', 'pr', 'submit' } do
      ok(vim.tbl_contains(subs, s), s)
    end
    eq({ 'approve', 'comment', 'request_changes' }, vim.fn.getcompletion('Redline submit ', 'cmdline'))
    for _, m in ipairs {
      { 'n', ' aa' },
      { 'n', ' as' },
      { 'n', ' ac' },
      { 'n', ' aC' },
      { 'x', ' av' },
      { 'n', ' ap' },
      { 'x', ' ap' },
      { 'n', '<C-.>' },
      { 't', '<C-.>' },
      { 'i', '<C-.>' },
      { 'n', ' rc' },
      { 'n', ']h' },
    } do
      ok(vim.fn.maparg(m[2], m[1]) ~= '' or vim.fn.mapcheck(m[2], m[1]) ~= '', m[1] .. ' ' .. m[2])
    end
  end)

  it('runs subcommands', function()
    h.wipe()
    local dir = h.repo { ['a.txt'] = 'a\n' }
    vim.cmd.cd(dir)
    vim.cmd 'Redline snapshot before refactor'
    eq('before refactor', require('redline.snapshot').list(dir)[1].label)
    h.open(dir, 'a.txt')
    vim.cmd '1Redline comment check this'
    local c = require('redline.review').db(dir).comments[1]
    eq('check this', c and c.text, vim.inspect(_G.NOTES[#_G.NOTES]))
  end)

  it('can skip keymaps', function()
    vim.keymap.del('n', '<leader>rv')
    require('redline').setup { keys = false }
    eq('', vim.fn.maparg('<leader>rv', 'n'))
  end)
end)
