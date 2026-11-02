---@class redline.Tool
---@field cmd string[]

---@class redline.WinOpts
---@field position 'right'|'left'|'bottom'|'top'
---@field size number Columns/rows, or a fraction of the editor when < 1

---@class redline.HerdrOpts
---@field enabled boolean
---@field bin? string Overrides $HERDR_BIN_PATH and `herdr`
---@field bracketed boolean Wrap send-text in bracketed paste markers

---@class redline.AgentOpts
---@field tools table<string, redline.Tool>
---@field default string
---@field win redline.WinOpts
---@field herdr redline.HerdrOpts
---@field focus boolean Focus the agent after sending
---@field submit_delay integer ms between paste and Enter
---@field prompts table<string, string>

---@class redline.SnapshotOpts
---@field keep integer

---@class redline.DiffOpts
---@field interval integer Poll interval in ms for checktime and file list; 0 disables
---@field debounce integer
---@field autoread boolean
---@field word boolean
---@field syntax boolean
---@field signs boolean
---@field max_bytes integer Skip files larger than this

---@class redline.WatchOpts
---@field enabled boolean Reload buffers whose files change on disk
---@field debounce integer ms
---@field max integer Most directories watched at once
---@field poll integer ms; timer for buffers without a watcher, 0 disables

---@class redline.ReviewOpts
---@field submit boolean Submit the review prompt instead of only inserting it
---@field header string
---@field sign string

---@class redline.PrOpts
---@field remote string
---@field backend? 'gh'|'forge'
---@field gh string
---@field forge string

---@class redline.Keys
---@field [string] string|false

---@class redline.Config
---@field agent redline.AgentOpts
---@field snapshot redline.SnapshotOpts
---@field diff redline.DiffOpts
---@field watch redline.WatchOpts
---@field review redline.ReviewOpts
---@field pr redline.PrOpts
---@field keys redline.Keys|false
---@field state_dir? string

local M = {}

---@type redline.Config
M.defaults = {
  agent = {
    tools = {
      claude = { cmd = { 'claude' } },
      codex = { cmd = { 'codex' } },
      pi = { cmd = { 'pi' } },
    },
    default = 'claude',
    win = { position = 'right', size = 0.4 },
    herdr = { enabled = true, bracketed = true },
    focus = true,
    submit_delay = 120,
    prompts = {
      explain = 'Explain {selection}. Do not rewrite the code. Focus on helping me understand it.',
      line = 'Explain what the code around my cursor does. Do not suggest edits unless I ask.\n\n{line}',
      error = 'Explain this diagnostic/error in simple terms and how I should think about it.\n\n{diagnostics}',
    },
  },
  snapshot = { keep = 20 },
  diff = {
    interval = 2000,
    debounce = 150,
    autoread = true,
    word = true,
    syntax = true,
    signs = true,
    max_bytes = 1024 * 1024,
  },
  watch = { enabled = true, debounce = 100, max = 256, poll = 3000 },
  review = {
    submit = true,
    header = 'I reviewed the code and left {count} comment(s). Please address each one.',
    sign = '▍',
  },
  pr = { remote = 'origin', gh = 'gh', forge = 'forge' },
  keys = {
    toggle = '<leader>aa',
    select = '<leader>as',
    codex = '<leader>ac',
    claude = '<leader>aC',
    send = '<leader>av',
    prompt = '<leader>ap',
    focus = '<C-.>',
    comment = '<leader>rc',
    edit = '<leader>re',
    delete = '<leader>rd',
    list = '<leader>rl',
    review_send = '<leader>rs',
    review_check = '<leader>rk',
    snapshot = '<leader>rS',
    diff = '<leader>rv',
    diff_pick = '<leader>rV',
    files = '<leader>rf',
    pr = '<leader>rp',
    pr_submit = '<leader>rP',
    next_hunk = ']h',
    prev_hunk = '[h',
  },
}

---@type redline.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  local o = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  -- Tools are replaced, not merged, so a user can drop the built-in ones.
  if opts and opts.agent and opts.agent.tools then
    o.agent.tools = opts.agent.tools
  end
  M.options = o
end

---@return string
function M.state_dir()
  return M.options.state_dir or (vim.fn.stdpath 'state' .. '/redline')
end

return M
