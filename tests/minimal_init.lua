local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
root = vim.fn.fnamemodify(root, ':p'):gsub('/$', '')
-- Keep only nvim's own runtime dirs (bundled parsers live outside VIMRUNTIME).
local rtp = { root }
for _, d in ipairs(vim.opt.rtp:get()) do
  if not vim.startswith(d, vim.env.HOME) then
    rtp[#rtp + 1] = d
  end
end
vim.opt.rtp = rtp
vim.opt.packpath = {}
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local bin = root .. '/tests/bin'

-- Fakes must win over anything real: the shell may export HERDR_BIN_PATH.
vim.env.PATH = bin .. ':' .. vim.env.PATH
vim.env.HERDR_BIN_PATH = bin .. '/herdr'
vim.env.HERDR_PANE_ID = nil
vim.env.REDLINE_FAKE_DIR = tmp .. '/fake'
vim.env.XDG_STATE_HOME = tmp .. '/state'
vim.env.GIT_CONFIG_GLOBAL = tmp .. '/gitconfig'
vim.env.GIT_CONFIG_NOSYSTEM = '1'
vim.env.GIT_TERMINAL_PROMPT = '0'
vim.env.GIT_AUTHOR_NAME = 'test'
vim.env.GIT_AUTHOR_EMAIL = 'test@example.com'
vim.env.GIT_COMMITTER_NAME = 'test'
vim.env.GIT_COMMITTER_EMAIL = 'test@example.com'
vim.fn.writefile({ '[init]', '\tdefaultBranch = main' }, tmp .. '/gitconfig')

for _, n in ipairs { 'herdr', 'gh', 'forge' } do
  local p = vim.fn.exepath(n)
  if p ~= bin .. '/' .. n then
    io.stderr:write('refusing to run: ' .. n .. ' resolves to ' .. p .. '\n')
    vim.cmd 'cquit 2'
  end
end

_G.TEST_TMP = tmp
_G.TEST_BIN = bin

_G.NOTES = {}
vim.notify = function(msg, level)
  table.insert(_G.NOTES, { msg = msg, level = level })
end
vim.cmd.runtime 'plugin/redline.lua'
