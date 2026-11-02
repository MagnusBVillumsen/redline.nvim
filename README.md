# redline.nvim

Review what your coding agent did without leaving the buffer.

redline runs or attaches to coding agents (Claude Code, Codex, pi, …), sends
them code with its location, lets you leave review comments on lines and send
them all as one prompt, and shows what changed as a GitHub-style inline diff
in the same buffer: removed lines as red virtual lines, new lines in green. It
also reviews pull requests on GitHub (`gh`) and Forgejo (`forge`).

- **Agents**: spawn an agent CLI in a terminal split, or attach to one that
  already runs in a [Herdr](https://github.com/herdrdev/herdr) pane.
- **Send with metadata**: `<leader>av` inserts `path:12-20:` plus a fenced
  code block into the agent's input, without submitting.
- **Review mode**: comments on lines or ranges, shown as virtual lines, kept
  per repository across restarts, sent as one structured prompt.
- **Snapshots**: the working tree (including untracked files) stored as a
  git commit under a private ref. Your index, HEAD, branches and stash are
  never touched. Sending a review takes one automatically.
- **Inline diff**: against HEAD, a merge-base or a snapshot, across all
  changed files, updated live while the agent edits. No side-by-side view.
- **Review check**: after the agent is done, diff against the review
  snapshot with every comment at its new location, marked touched or
  untouched.
- **Auto-reload**: buffers whose files change on disk reload on their own,
  without relying on focus events; unsaved changes are never overwritten.
- **PR review**: pick a PR, check it out, see the diff against the
  merge-base with existing comments inline, add your own, submit.

Requires Neovim 0.11+ (developed on 0.12) and git. No plugin dependencies;
pickers go through `vim.ui.select`, so telescope-ui-select or similar is used
when installed.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'MagnusBVillumsen/redline.nvim',
  event = 'VeryLazy',
  opts = {},
}
```

The `:Redline` command exists before `setup()` runs, so `cmd = 'Redline'` works
for lazy loading too, but then the default keymaps are only set once the plugin
loads.

## Keymaps

Set by `setup()`. Change any of them with `keys = { name = '<lhs>' }`, drop one
with `name = false`, or all with `keys = false`.

| Key          | Mode    | Name           | Action                                          |
| ------------ | ------- | -------------- | ----------------------------------------------- |
| `<leader>aa` | n       | `toggle`       | Toggle the agent window (or pick an agent)      |
| `<leader>as` | n       | `select`       | Pick an agent: running, Herdr pane, or start one |
| `<leader>ac` | n       | `codex`        | Toggle Codex                                    |
| `<leader>aC` | n       | `claude`       | Toggle Claude                                   |
| `<leader>av` | x       | `send`         | Send selection with path and lines, no submit  |
| `<leader>ap` | n, x    | `prompt`       | Prompt picker                                   |
| `<C-.>`      | n,t,i,x | `focus`        | Jump to the agent and back                      |
| `<leader>rc` | n, x    | `comment`      | Add a review comment on the line or range      |
| `<leader>re` | n       | `edit`         | Edit the comment under the cursor               |
| `<leader>rd` | n       | `delete`       | Delete the comment under the cursor             |
| `<leader>rl` | n       | `list`         | All comments in quickfix                        |
| `<leader>rs` | n       | `review_send`  | Snapshot, then send all comments as one prompt  |
| `<leader>rk` | n       | `review_check` | Diff vs the review snapshot, comments mapped    |
| `<leader>rS` | n       | `snapshot`     | Take a snapshot (asks for a label)              |
| `<leader>rv` | n       | `diff`         | Toggle the inline diff vs HEAD                  |
| `<leader>rV` | n       | `diff_pick`    | Inline diff against HEAD, a merge-base or snapshot |
| `<leader>rf` | n       | `files`        | Picker over changed files                       |
| `<leader>rp` | n       | `pr`           | Pick a PR and start reviewing it                |
| `<leader>rP` | n       | `pr_submit`    | Submit the PR review                            |
| `]h` / `[h`  | n       | `next_hunk`… | Next / previous hunk across all changed files |

In the comment editor: `<C-s>`, `:w` or `<CR>` (normal mode) saves, `q` or
`<Esc>` cancels.

## Commands

`:Redline <sub>`, with completion:

| Command                          | Action                                             |
| -------------------------------- | -------------------------------------------------- |
| `toggle [tool]`, `select`, `focus` | Agent window                                      |
| `[range]send [text]`             | Send text, or the range/current line with metadata |
| `prompt [name]`                  | Send a configured prompt                           |
| `[range]comment [text]`          | Add a comment (opens the editor without text)      |
| `edit`, `delete`                 | Comment under the cursor                           |
| `comments`, `pick`               | Comments in quickfix / picker                      |
| `review`                         | Snapshot and send all pending comments             |
| `check`                          | Diff vs the latest review snapshot                 |
| `clear [all]`                    | Drop sent comments, or all                         |
| `snapshot [label]`, `snapshots`  | Take one / diff against one                        |
| `diff [rev]`, `base`, `off`      | Inline diff toggle or vs rev / pick base / off     |
| `files`, `qf`, `next`, `prev`    | Changed files, hunks in quickfix, hunk navigation  |
| `pr [number]`, `submit [event] [body]`, `close` | PR review                           |
| `reload`, `reload!`              | Reload from disk; `!` drops unsaved changes        |
| `diskdiff`                       | Toggle an inline diff of the buffer vs the disk    |

## Configuration

Defaults:

```lua
require('redline').setup {
  agent = {
    tools = { -- replaces the table, it is not merged
      claude = { cmd = { 'claude' } },
      codex = { cmd = { 'codex' } },
      pi = { cmd = { 'pi' } },
    },
    default = 'claude',
    win = { position = 'right', size = 0.4 }, -- right|left|bottom|top; < 1 is a fraction
    herdr = { enabled = true, bin = nil, bracketed = true },
    focus = true, -- focus the agent after sending
    submit_delay = 120, -- ms between paste and Enter in nvim terminals
    prompts = {
      explain = 'Explain {selection}. Do not rewrite the code. Focus on helping me understand it.',
      line = 'Explain what the code around my cursor does. Do not suggest edits unless I ask.\n\n{line}',
      error = 'Explain this diagnostic/error in simple terms and how I should think about it.\n\n{diagnostics}',
    },
  },
  snapshot = { keep = 20 },
  diff = {
    interval = 2000, -- ms; checktime and file list refresh while the diff is on (0 = off)
    debounce = 150,
    autoread = true, -- sets 'autoread' locally on diffed buffers
    word = true, -- word-level highlights
    syntax = true, -- treesitter highlights in removed lines
    signs = true,
    max_bytes = 1048576,
  },
  watch = {
    enabled = true, -- reload buffers changed on disk
    debounce = 100, -- ms
    max = 256, -- most directories watched at once
    poll = 3000, -- ms; fallback timer for buffers without a watcher (0 = off)
  },
  review = {
    submit = true, -- submit the review prompt, not only insert it
    header = 'I reviewed the code and left {count} comment(s). Please address each one.',
    sign = '▍',
  },
  pr = { remote = 'origin', backend = nil, gh = 'gh', forge = 'forge' },
  keys = { --[[ see the table above ]] },
  state_dir = nil, -- default: stdpath('state') .. '/redline'
}
```

### Placeholders

Prompts and `:Redline send` text expand `{selection}`, `{line}`, `{file}`,
`{position}`, `{this}`, `{f}` (or `{function}`), `{c}` (or `{class}`),
`{diagnostics}`, `{diagnostics_all}`, `{buffers}` and `{quickfix}`. Unknown
names stay as they are. `{f}` and `{c}` are the innermost function and
class/struct/impl around the cursor, found with treesitter, in the same format
as `{selection}`. `{selection}` and `{line}` give
the repo-relative path and lines followed by a fenced block:

````
lua/foo.lua:12-20:
```lua
…
```
````

### Highlights

All are defined with `default = true`, so your colorscheme or config wins:
`RedlineAdd`, `RedlineAddText`, `RedlineAddSign`, `RedlineDelete`,
`RedlineDeleteText`, `RedlineComment`, `RedlineCommentSign`,
`RedlinePrComment`, `RedlineTouched`, `RedlineUntouched`.

## How it works

### Agents and Herdr

`select` lists running terminal sessions, agent panes from `herdr agent list`
(the ones whose cwd is inside the current repo first, marked ★), and installed
tools you can start. The Herdr binary is `$HERDR_BIN_PATH` if set, else
`herdr`.

Sending without submitting:

- **nvim terminal**: the text is wrapped in bracketed paste markers
  (`ESC[200~ … ESC[201~`), so newlines do not submit.
- **Herdr pane**: `herdr pane send-text <pane> <text>`. In Herdr 0.9.5,
  `send-text` writes the bytes to the pane unchanged and does not add
  bracketed paste (only `agent prompt` and `pane run` do, through the API's
  `send_input` path). redline therefore wraps the text in the bracketed paste
  markers itself. Claude Code, Codex and pi all turn on bracketed paste, so the
  text lands in the input as one paste and newlines do not submit. If an agent
  does not support bracketed paste the markers would show up as text; set
  `agent.herdr.bracketed = false` and redline sends the text on one line
  instead (newlines replaced by spaces).

Submitting (review prompts with `review.submit = true`): nvim terminals get
the paste followed by Enter after `submit_delay` ms; Herdr panes get
`herdr agent prompt <pane> <text>`, which pastes and presses Enter itself.

Herdr's CLI rejects an argument that starts with `-`, so redline puts a space
in front of such text.

### Snapshots

A snapshot is a commit of the whole working tree, including untracked files
that are not ignored. It is built with a temporary index: the real index is
copied (so `git add -A` can reuse its stat info), then `GIT_INDEX_FILE=<copy>
git add -A`, `write-tree` and `commit-tree` with HEAD as parent. The commit is
stored at `refs/redline/snapshots/<worktree>/<n>` (`<worktree>` is `main` for
the main worktree, else the worktree's name), so each worktree has its own
list. The commit message is the label. Only the newest `snapshot.keep` are kept.
Nothing touches your index, HEAD, branches or stash. Snapshots are only taken
when you ask, or when you send a review.

To drop them all: `git for-each-ref --format='%(refname)' refs/redline | xargs -n1 git update-ref -d`.

### Inline diff

For every buffer in the repo, the base version comes from `git cat-file` and is
diffed against the buffer with `vim.text.diff`. The list of changed files is
`git diff-tree` between the base and a temporary-index tree of the working
tree, so new untracked files show up too. While the diff is on, redline runs
`:checktime` every `diff.interval` ms and redraws (debounced) on edits, so
changes the agent makes appear as they happen. That check goes through the
auto-reload logic below, so it never prompts and never touches buffers with
unsaved changes; file events from the watcher refresh the diff as well.

### Auto-reload

With an agent in another Herdr pane editing files, the buffer would otherwise
stay stale until a focus event triggers `:checktime`, and focus events are
unreliable inside a multiplexer. redline watches the parent directory of every
loaded, listed file buffer with `vim.uv` fs events (a directory watch survives
tools that write a temp file and rename it over the original), debounces, and
compares the file's mtime, size and inode with what the buffer last read.

- **Unmodified buffer**: reloaded silently; every window keeps its view.
- **Buffer with unsaved changes**: never reloaded. You get one warning per
  change on disk; `:Redline reload!` loads the disk version (dropping your
  changes) and `:Redline diskdiff` shows the disk version inline, in red, over
  your buffer.

Watchers are removed when buffers are unloaded or wiped, at most `watch.max`
directories are watched, and buffers past the cap or whose watcher fails are
checked by a timer every `watch.poll` ms. `FocusGained`, `BufEnter` and
`CursorHold` also trigger a check. The same events refresh the inline diff,
so its file list and highlights follow the agent's edits. Turn it off with
`watch = { enabled = false }`.

### Review comments

Comments are stored per repository root (each worktree separately) in
`stdpath('state')/redline/comments/`. They follow edits through extmarks.
`review` sends every pending comment as one prompt:

````
I reviewed the code and left 2 comment(s). Please address each one.

## 1. lua/foo.lua:12-20

```lua
…the code as it is now…
```

Rename this.
````

Right before sending, a snapshot is taken and linked to the comments. `check`
then opens the inline diff against that snapshot and shows each comment at its
mapped location, marked **✓ touched** when a hunk overlaps or directly borders
its lines and **✗ untouched** otherwise. The same list goes to quickfix.

### PR review

The backend comes from the remote URL: `github.com` uses `gh`, anything else
`forge`. Set `pr.backend` to force one.

1. `:Redline pr` lists open PRs and you pick one.
2. If HEAD is not the PR head, redline checks it out (`gh pr checkout N` /
   `forge pr checkout N`). With uncommitted changes it refuses and suggests
   a `git worktree add`.
3. The inline diff runs against `git merge-base HEAD <remote>/<base>` (the base
   is fetched first).
4. Existing review comments are shown inline, read-only, with their author.
5. Comments you add now belong to this PR, not to the agent review.
6. `:Redline submit` asks for the event (comment, approve, request changes) and
   a body, and submits all of them as one review on the PR head commit:
   - gh: `gh api -X POST repos/{owner}/{repo}/pulls/N/reviews` with `line`,
     `side` and `start_line`;
   - forge: `forge pr review N submit --approve|--request-changes|--comment
     --body-file F --comments-file F --commit SHA`.

## Migrating from sidekick.nvim

redline's defaults use sidekick's keys with the same meaning, so swapping the
spec is enough for most setups:

```lua
-- before
{ 'folke/sidekick.nvim', opts = { cli = { prompts = { … } } }, keys = { … } },
-- after
{ 'MagnusBVillumsen/redline.nvim', event = 'VeryLazy', opts = { agent = { prompts = { … } } } },
```

| sidekick                                             | redline                                  |
| ---------------------------------------------------- | ---------------------------------------- |
| `require('sidekick.cli').toggle()`                   | `require('redline.agent').toggle()`      |
| `.select({ filter = { installed = true } })`         | `require('redline.agent').select()`      |
| `.toggle({ name = 'codex', focus = true })`          | `require('redline.agent').toggle { name = 'codex', focus = true }` |
| `.send({ msg = '{selection}' })`                     | `require('redline.agent').send_selection()` (adds path and lines) |
| `.prompt()`                                          | `require('redline.agent').prompt()`      |
| `.focus()`                                           | `require('redline.agent').focus()`       |
| `cli.prompts`                                        | `agent.prompts`, same placeholders       |
| `cli.tools`                                          | `agent.tools` (`{ cmd = { … } }`)         |
| `cli.mux` (tmux/zellij)                              | Herdr panes via `herdr agent list`       |
| `nes` (Copilot next edit)                            | not provided                             |

Differences: `<leader>av` adds the file path and line range and a fenced
block instead of the raw selection; `{function}` and `{class}` also have the
short forms `{f}` and `{c}`; there is no tmux/zellij backend.

## Development

```sh
nix develop   # neovim, git, stylua
make test     # headless tests against temporary git repos
make lint     # stylua --check
nix flake check
```

The tests use fake `herdr`, `gh` and `forge` executables (`tests/bin/fake`)
that record their arguments and return canned JSON; `tests/minimal_init.lua`
refuses to run if any of the three resolves to a real binary.

## License

MIT
