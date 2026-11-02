local config = require 'redline.config'
local util = require 'redline.util'

local M = {}

---@class redline.Pane
---@field pane_id string
---@field agent string
---@field agent_status string
---@field cwd string
---@field title string
---@field workspace_id string
---@field in_repo boolean

---@return string
function M.bin()
  local b = config.options.agent.herdr.bin
  if b and b ~= '' then
    return b
  end
  local env = vim.env.HERDR_BIN_PATH
  return (env and env ~= '') and env or 'herdr'
end

---@return boolean
function M.available()
  return config.options.agent.herdr.enabled and vim.fn.executable(M.bin()) == 1
end

--- Herdr's CLI treats a leading `-` as an option, so such text gets a space.
---@param s string
---@return string
function M.arg(s)
  return s:sub(1, 1) == '-' and (' ' .. s) or s
end

---@param args string[]
---@return redline.Result
function M.run(args)
  local cmd = { M.bin() }
  vim.list_extend(cmd, args)
  return util.run(cmd, { timeout = 10000 })
end

---@param dir string
---@param root string
---@return boolean
local function inside(dir, root)
  dir = vim.fs.normalize(dir)
  return dir == root or dir:sub(1, #root + 1) == root .. '/'
end

--- Agent panes, the ones whose cwd is inside `root` first.
---@param root? string
---@return redline.Pane[]
function M.list(root)
  if not M.available() then
    return {}
  end
  local r = M.run { 'agent', 'list' }
  local data = r.code == 0 and util.json(r.stdout) or nil
  local agents = data and (data.result and data.result.agents or data.agents) or {}
  local res = {}
  for _, a in ipairs(agents) do
    if a.pane_id and a.pane_id ~= vim.env.HERDR_PANE_ID then
      local cwd = a.foreground_cwd or a.cwd or ''
      res[#res + 1] = {
        pane_id = a.pane_id,
        agent = a.agent or '?',
        agent_status = a.agent_status or '?',
        cwd = cwd,
        title = a.terminal_title_stripped or a.terminal_title or '',
        workspace_id = a.workspace_id or '',
        in_repo = root ~= nil and (inside(cwd, root) or inside(a.cwd or '', root)),
      }
    end
  end
  table.sort(res, function(a, b)
    if a.in_repo ~= b.in_repo then
      return a.in_repo
    end
    return a.pane_id < b.pane_id
  end)
  return res
end

--- Inserts text without submitting. send-text writes raw bytes to the pane,
--- so newlines would act as Enter; the bracketed paste markers make the
--- agent's TUI treat the whole text as one paste.
---@param pane string
---@param text string
---@return boolean, string?
function M.send(pane, text)
  if config.options.agent.herdr.bracketed then
    text = '\27[200~' .. text .. '\27[201~'
  else
    text = text:gsub('\r?\n', ' ')
  end
  local r = M.run { 'pane', 'send-text', pane, M.arg(text) }
  return r.code == 0, util.trim(r.stderr)
end

--- Submits text as a prompt; Herdr handles paste and Enter itself.
---@param pane string
---@param text string
---@return boolean, string?
function M.prompt(pane, text)
  local r = M.run { 'agent', 'prompt', pane, M.arg(text) }
  return r.code == 0, util.trim(r.stderr)
end

---@param pane string
---@return boolean
function M.focus(pane)
  return M.run({ 'agent', 'focus', pane }).code == 0
end

return M
