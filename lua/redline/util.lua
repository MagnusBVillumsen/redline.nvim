local M = {}

---@class redline.Result
---@field code integer
---@field stdout string
---@field stderr string

---@param cmd string[]
---@param opts? {cwd?: string, env?: table<string,string>, stdin?: string, timeout?: integer}
---@return redline.Result
function M.run(cmd, opts)
  opts = opts or {}
  local ok, obj = pcall(vim.system, cmd, { cwd = opts.cwd, env = opts.env, stdin = opts.stdin, text = true })
  if not ok then
    return { code = 127, stdout = '', stderr = tostring(obj) }
  end
  local r = obj:wait(opts.timeout or 60000)
  return { code = r.code, stdout = r.stdout or '', stderr = r.stderr or '' }
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'redline' })
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---@param s string
---@return string
function M.trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param s string
---@return string[]
function M.lines(s)
  if s == '' then
    return {}
  end
  local t = vim.split(s, '\n', { plain = true })
  if t[#t] == '' then
    t[#t] = nil
  end
  return t
end

---@param s string
---@return any?
function M.json(s)
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and v or nil
end

---@param path string
---@return string?
function M.read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read '*a'
  f:close()
  return s
end

---@param path string
---@param s string
---@return boolean
function M.write(path, s)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'wb')
  if not f then
    return false
  end
  f:write(s)
  f:close()
  return os.rename(tmp, path)
end

---@param fn function
---@param ms integer
---@return function
function M.debounce(fn, ms)
  local timer = assert(vim.uv.new_timer())
  return function(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

---@param ft string
---@return string
function M.lang(ft)
  local ok, l = pcall(vim.treesitter.language.get_lang, ft)
  return (ok and l) or ft
end

---@param text string
---@return string
function M.fence(text)
  local n = 3
  for run in text:gmatch '`+' do
    n = math.max(n, #run + 1)
  end
  return string.rep('`', n)
end

---@param code string
---@param ft string
---@return string
function M.codeblock(code, ft)
  local f = M.fence(code)
  return f .. (ft or '') .. '\n' .. code .. (code:sub(-1) == '\n' and '' or '\n') .. f
end

---@param l1 integer
---@param l2 integer
---@return string
function M.range(l1, l2)
  return l1 == l2 and tostring(l1) or (l1 .. '-' .. l2)
end

return M
