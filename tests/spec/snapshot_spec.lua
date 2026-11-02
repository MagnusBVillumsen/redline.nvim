local h = require 'tests.helpers'
local config = require 'redline.config'
local git = require 'redline.git'
local snapshot = require 'redline.snapshot'

---@param dir string
---@return table
local function state(dir)
  local idx = h.sh('git rev-parse --git-path index', dir)
  if idx:sub(1, 1) ~= '/' then
    idx = dir .. '/' .. idx
  end
  return {
    index = vim.fn.readblob(idx),
    status = h.sh('git status --porcelain=v1 -uall', dir),
    head = h.sh('git rev-parse HEAD', dir),
    branch = h.sh('git symbolic-ref -q HEAD || true', dir),
    branches = h.sh('git for-each-ref --format="%(refname) %(objectname)" refs/heads', dir),
    stash = h.sh('git stash list', dir),
  }
end

local function tree(dir, sha)
  return vim.split(h.sh('git ls-tree -r --name-only ' .. sha, dir), '\n')
end

describe('snapshot', function()
  before_each(function()
    config.setup()
  end)

  it('captures tracked, staged and untracked files without touching index, HEAD or stash', function()
    local dir = h.repo { ['a.txt'] = 'a\n', ['.gitignore'] = '*.log\n' }
    h.write(dir, { ['a.txt'] = 'a changed\n', ['b.txt'] = 'staged\n', ['c.txt'] = 'untracked\n', ['d.log'] = 'ignored\n', ['sub/e.txt'] = 'e\n' })
    h.sh('git add b.txt', dir)
    local before = state(dir)

    local s = ok(snapshot.create(dir, 'my label'))
    eq(before, state(dir))
    eq({ '.gitignore', 'a.txt', 'b.txt', 'c.txt', 'sub/e.txt' }, tree(dir, s.sha))
    eq('a changed', h.sh('git cat-file blob ' .. s.sha .. ':a.txt', dir))
    eq(before.head, h.sh('git rev-parse ' .. s.sha .. '^', dir))
    eq('refs/redline/snapshots/main/1', s.ref)

    local list = snapshot.list(dir)
    eq(1, #list)
    eq('my label', list[1].label)
    eq(s.sha, list[1].sha)
    ok(math.abs(list[1].time - os.time()) < 60)
  end)

  it('sees same-size edits made in the same second as the index write', function()
    local dir = h.repo { ['a.txt'] = 'aaa\n' }
    for i = 1, 5 do
      local v = string.rep(tostring(i), 3)
      h.write(dir, { ['a.txt'] = v .. '\n' })
      local s = ok(snapshot.create(dir, 'racy ' .. i))
      eq(v, h.sh('git cat-file blob ' .. s.sha .. ':a.txt', dir))
    end
  end)

  it('works in a repository without commits', function()
    local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    h.sh('git init -q', dir)
    h.write(dir, { ['x.txt'] = 'x\n' })
    local s = ok(snapshot.create(dir, 'first'))
    eq({ 'x.txt' }, tree(dir, s.sha))
    eq('', h.sh('git ls-files', dir))
  end)

  it('prunes to the newest N', function()
    config.setup { snapshot = { keep = 3 } }
    local dir = h.repo { ['a.txt'] = 'a\n' }
    for i = 1, 5 do
      h.write(dir, { ['a.txt'] = 'v' .. i .. '\n' })
      ok(snapshot.create(dir, 'snap ' .. i))
    end
    local list = snapshot.list(dir)
    eq(
      { 5, 4, 3 },
      vim.tbl_map(function(s)
        return s.n
      end, list)
    )
    eq('snap 5', list[1].label)
    eq(3, #vim.split(h.sh('git for-each-ref refs/redline', dir), '\n'))
  end)

  it('keeps snapshots per worktree and uses the worktree index', function()
    local dir = h.repo { ['a.txt'] = 'a\n' }
    local wt = dir .. '-wt'
    h.sh('git worktree add -q -b feat ' .. wt, dir)
    wt = vim.uv.fs_realpath(wt)
    h.write(wt, { ['a.txt'] = 'in worktree\n', ['new.txt'] = 'new\n' })
    local before = state(wt)
    local main_before = state(dir)

    eq(wt, git.root(wt .. '/a.txt'))
    local s = ok(snapshot.create(wt, 'wt snap'))
    eq(before, state(wt))
    eq(main_before, state(dir))
    ok(s.ref:find('^refs/redline/snapshots/' .. vim.pesc(vim.fs.basename(wt)) .. '/1$'), s.ref)
    eq({ 'a.txt', 'new.txt' }, tree(wt, s.sha))
    eq(1, #snapshot.list(wt))
    eq(0, #snapshot.list(dir))
  end)
end)
