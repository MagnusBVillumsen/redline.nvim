local h = require 'tests.helpers'
local config = require 'redline.config'
local inline = require 'redline.inline'
local pr = require 'redline.pr'
local review = require 'redline.review'

--- A repo whose origin is a local bare repo under a github.com-like or
--- forge-like path, with a feature branch one commit ahead of main.
---@param host string
---@return string dir, string head
local function setup_repo(host)
  local dir = h.repo { ['a.lua'] = 'one\ntwo\nthree\n' }
  local bare = vim.fn.tempname() .. '/' .. host .. '/me/repo.git'
  vim.fn.mkdir(bare, 'p')
  h.sh('git init -q --bare ' .. bare, dir)
  h.sh('git remote add origin ' .. bare .. ' && git push -q origin main', dir)
  h.sh('git checkout -q -b feature && printf "one\\nTWO\\nthree\\nfour\\n" > a.lua && git commit -qam feature', dir)
  local head = h.sh('git rev-parse HEAD', dir)
  h.sh('git checkout -q main', dir)
  vim.env.REDLINE_FAKE_CHECKOUT = 'feature'
  return dir, head
end

local function argv(name, sub)
  return vim.tbl_filter(function(c)
    return table.concat(c.argv, ' '):find(sub, 1, true) ~= nil
  end, h.calls(name))
end

describe('pr', function()
  before_each(function()
    config.setup { diff = { interval = 0 }, state_dir = vim.fn.tempname() }
    review.dbs = {}
    review.marks = {}
    pr.state = nil
    inline.disable()
    h.wipe()
    h.fake_reset()
  end)

  it('picks the backend from the remote', function()
    local dir = h.repo()
    h.sh('git remote add origin git@github.com:me/repo.git', dir)
    eq('gh', pr.backend(dir).name)
    h.sh('git remote set-url origin ssh://git@heimdall:2222/me/repo.git', dir)
    eq('forge', pr.backend(dir).name)
  end)

  it('gh: checks out, diffs against the merge-base, shows comments and submits a review', function()
    local dir, head = setup_repo 'github.com'
    vim.cmd.cd(dir)
    h.reply(
      'gh',
      'pr list *',
      vim.json.encode {
        { number = 7, title = 'Feature', author = { login = 'bob' }, headRefName = 'feature', headRefOid = head, baseRefName = 'main', url = 'u' },
      }
    )
    h.reply(
      'gh',
      'api --paginate *',
      vim.json.encode { { path = 'a.lua', line = 2, side = 'RIGHT', user = { login = 'ann' }, body = 'Why caps?' } }
        .. '\n'
        .. vim.json.encode {
          { path = 'a.lua', line = vim.NIL, original_line = 1, side = 'RIGHT', user = { login = 'cy' }, body = 'old one' },
        }
    )
    pr.open(7)
    eq(1, #argv('gh', 'pr checkout 7'))
    eq(head, h.sh('git rev-parse HEAD', dir))
    ok(inline.active())
    local mb = h.sh('git merge-base HEAD main', dir)
    eq(mb, inline.state.sha)
    eq(2, #pr.state.comments)
    eq(true, pr.state.comments[2].outdated)

    local buf = h.open(dir, 'a.lua')
    local shown = {}
    for _, m in ipairs(h.marks(buf, pr.ns)) do
      shown[#shown + 1] = { m[2], vim.trim(m[4].virt_lines[1][2][1]) }
    end
    eq({ { 0, '@cy (outdated): old one' }, { 1, '@ann: Why caps?' } }, shown)

    review.add { buf = buf, l1 = 2, l2 = 4, text = 'Range comment' }
    review.add { buf = buf, l1 = 1, text = 'Single' }
    review.add { buf = buf, l1 = 3, text = 'Draft' }
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    review.delete()
    eq(2, #review.pending(dir, 7))
    eq(0, #review.pending(dir))

    h.reply('gh', 'api -X POST *', '{"id": 1}')
    pr.submit { event = 'request_changes', body = '-please fix' }
    local post = argv('gh', 'api -X POST')
    eq(1, #post)
    eq({ 'gh', 'api', '-X', 'POST', 'repos/{owner}/{repo}/pulls/7/reviews', '--input' }, vim.list_slice(post[1].argv, 1, 6))
    eq({
      event = 'REQUEST_CHANGES',
      body = '-please fix',
      commit_id = head,
      comments = {
        { path = 'a.lua', line = 1, side = 'RIGHT', body = 'Single' },
        { path = 'a.lua', line = 4, side = 'RIGHT', start_line = 2, start_side = 'RIGHT', body = 'Range comment' },
      },
    }, vim.json.decode(post[1].files.input))
    eq(0, #review.pending(dir, 7))
  end)

  it('refuses to check out over a dirty tree', function()
    local dir, head = setup_repo 'github.com'
    vim.cmd.cd(dir)
    h.write(dir, { ['a.lua'] = 'dirty\n' })
    h.reply(
      'gh',
      'pr list *',
      vim.json.encode { { number = 7, title = 'F', author = { login = 'b' }, headRefName = 'feature', headRefOid = head, baseRefName = 'main' } }
    )
    pr.open(7)
    eq(0, #argv('gh', 'pr checkout'))
    eq(false, inline.active())
    ok(_G.NOTES[#_G.NOTES].msg:find('worktree', 1, true))
  end)

  it('forge: reads review comments and submits with a comments file', function()
    local dir, head = setup_repo 'heimdall'
    vim.cmd.cd(dir)
    h.reply(
      'forge',
      'pr list --json',
      vim.json.encode { { number = 3, title = 'F', user = { login = 'bob' }, head = { ref = 'feature', sha = head }, base = { ref = 'main' } } }
    )
    h.reply(
      'forge',
      'pr review 3 list --comments --json',
      vim.json.encode {
        {
          user = { login = 'ann' },
          comments = {
            { path = 'a.lua', position = 2, original_position = 0, body = 'new side', user = { login = 'ann' } },
            { path = 'a.lua', position = 0, original_position = 2, body = 'old side', user = { login = 'ann' } },
          },
        },
      }
    )
    pr.open(3)
    eq(1, #argv('forge', 'pr checkout 3'))
    eq(
      { 'new', 'old' },
      vim.tbl_map(function(c)
        return c.side
      end, pr.state.comments)
    )

    local buf = h.open(dir, 'a.lua')
    review.add { buf = buf, l1 = 2, l2 = 3, text = 'Hmm' }
    review.add { buf = buf, l1 = 4, text = 'Ok' }
    pr.submit { event = 'approve', body = 'LGTM' }
    local sub = argv('forge', 'review 3 submit')
    eq(1, #sub)
    local a = sub[1].argv
    eq({ 'forge', 'pr', 'review', '3', 'submit', '--approve', '--body-file' }, vim.list_slice(a, 1, 7))
    eq({ '--comments-file' }, vim.list_slice(a, 9, 9))
    eq({ '--commit', head }, vim.list_slice(a, 11, 12))
    eq('LGTM', sub[1].files['body-file'])
    eq({
      { path = 'a.lua', line = 2, end_line = 3, side = 'new', body = 'Hmm' },
      { path = 'a.lua', line = 4, side = 'new', body = 'Ok' },
    }, vim.json.decode(sub[1].files['comments-file']))
  end)
end)
