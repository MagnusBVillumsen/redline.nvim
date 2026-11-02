local config = require 'redline.config'
local context = require 'redline.context'
local git = require 'redline.git'
local herdr = require 'redline.herdr'
local term = require 'redline.terminal'
local util = require 'redline.util'

local M = {}

---@alias redline.Target {kind: 'term', name: string}|{kind: 'herdr', pane: redline.Pane}

---@type redline.Target?
M.target = nil

---@return string
local function cwd()
  return git.root() or vim.fn.getcwd()
end

---@return redline.Term?
local function cur_term()
  local t = M.target
  if t and t.kind == 'term' then
    local s = term.sessions[t.name]
    if s and term.alive(s) then
      return s
    end
  end
end

---@param name string
---@param focus boolean
---@return redline.Term?
function M.spawn(name, focus)
  local tool = config.options.agent.tools[name]
  if not tool then
    util.err('Unknown agent tool: ' .. name)
    return nil
  end
  local s = term.spawn(name, tool.cmd, cwd(), focus)
  if not s then
    util.err('Could not start ' .. table.concat(tool.cmd, ' '))
    return nil
  end
  M.target = { kind = 'term', name = name }
  return s
end

---@param opts? {name?: string, focus?: boolean}
function M.toggle(opts)
  opts = opts or {}
  local focus = opts.focus ~= false
  if opts.name then
    local s = term.sessions[opts.name]
    if s and term.alive(s) then
      M.target = { kind = 'term', name = opts.name }
      if term.win(s) then
        return term.hide(s)
      end
      return term.show(s, focus)
    end
    return M.spawn(opts.name, focus)
  end
  local s = cur_term()
  if s then
    if term.win(s) then
      return term.hide(s)
    end
    return term.show(s, focus)
  end
  if M.target and M.target.kind == 'herdr' then
    return herdr.focus(M.target.pane.pane_id)
  end
  M.select()
end

---@class redline.Choice
---@field label string
---@field run fun()

---@param cb? fun()
function M.select(cb)
  local root = git.root()
  ---@type redline.Choice[]
  local items = {}
  for name, s in pairs(term.sessions) do
    if term.alive(s) then
      items[#items + 1] = {
        label = string.format('● %s (nvim terminal)', name),
        run = function()
          M.target = { kind = 'term', name = name }
          term.show(s, cb == nil)
        end,
      }
    end
  end
  for _, p in ipairs(herdr.list(root)) do
    items[#items + 1] = {
      label = string.format(
        '%s %s [%s] %s  %s  (herdr %s)',
        p.in_repo and '★' or '○',
        p.agent,
        p.agent_status,
        p.title,
        vim.fn.fnamemodify(p.cwd, ':~'),
        p.pane_id
      ),
      run = function()
        M.target = { kind = 'herdr', pane = p }
        util.notify('Attached to herdr pane ' .. p.pane_id .. ' (' .. p.agent .. ')')
      end,
    }
  end
  local names = vim.tbl_keys(config.options.agent.tools)
  table.sort(names)
  for _, name in ipairs(names) do
    local tool = config.options.agent.tools[name]
    if not term.sessions[name] and vim.fn.executable(tool.cmd[1]) == 1 then
      items[#items + 1] = {
        label = '+ start ' .. name,
        run = function()
          M.spawn(name, cb == nil)
        end,
      }
    end
  end
  if #items == 0 then
    return util.warn 'No agents found or installed'
  end
  vim.ui.select(items, {
    prompt = 'Agent',
    format_item = function(i)
      return i.label
    end,
  }, function(i)
    if i then
      i.run()
      if cb then
        vim.schedule(cb)
      end
    end
  end)
end

--- Jumps between the agent and the previous window.
function M.focus()
  if vim.b.redline_agent then
    vim.cmd.stopinsert()
    vim.cmd.wincmd 'p'
    return
  end
  local s = cur_term()
  if s then
    return term.show(s, true)
  end
  if M.target and M.target.kind == 'herdr' then
    return herdr.focus(M.target.pane.pane_id)
  end
  M.select()
end

---@class redline.SendOpts
---@field submit? boolean
---@field focus? boolean

--- Sends text to the current target, asking for one first if needed.
---@param text string
---@param opts? redline.SendOpts
---@param done? fun(ok: boolean)
function M.send(text, opts, done)
  opts = opts or {}
  local focus = opts.focus
  if focus == nil then
    focus = config.options.agent.focus
  end
  local t = M.target
  if not t or (t.kind == 'term' and not cur_term()) then
    return M.select(function()
      if M.target then
        M.send(text, opts, done)
      end
    end)
  end
  local ok, err = true, nil
  if t.kind == 'term' then
    local s = assert(cur_term())
    term.send(s, text, opts.submit == true)
    term.show(s, focus)
  else
    local pane = t.pane.pane_id
    if opts.submit then
      ok, err = herdr.prompt(pane, text)
    else
      ok, err = herdr.send(pane, text)
    end
    if ok and focus then
      herdr.focus(pane)
    end
  end
  if not ok then
    util.err('Send failed: ' .. (err or ''))
  end
  if done then
    done(ok)
  end
end

--- `<leader>av`: the selection with path and line range, not submitted.
function M.send_selection()
  local ctx = context.get()
  M.send(context.selection(ctx), { submit = false })
end

---@param name? string
function M.prompt(name)
  local ctx = context.get()
  local prompts = config.options.agent.prompts
  local function go(n)
    local tpl = prompts[n]
    if not tpl then
      return util.err('Unknown prompt: ' .. n)
    end
    M.send(context.render(tpl, ctx), { submit = false })
  end
  if name then
    return go(name)
  end
  local names = vim.tbl_keys(prompts)
  table.sort(names)
  vim.ui.select(names, {
    prompt = 'Prompt',
    format_item = function(n)
      return string.format('%-10s %s', n, (prompts[n]:gsub('\n.*', '')))
    end,
  }, function(n)
    if n then
      go(n)
    end
  end)
end

return M
