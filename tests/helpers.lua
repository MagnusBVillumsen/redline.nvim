local M = {}

---@param cmd string
---@param cwd? string
---@return string
function M.sh(cmd, cwd)
  local r = vim.system({ 'sh', '-c', cmd }, { cwd = cwd, text = true }):wait()
  if r.code ~= 0 then
    error(('command failed (%d): %s\n%s%s'):format(r.code, cmd, r.stdout, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end

---@param files? table<string, string>
---@return string
function M.repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  M.sh('git init -q && git commit -q --allow-empty -m init', dir)
  if files then
    M.write(dir, files)
    M.sh('git add -A && git commit -q -m files', dir)
  end
  return dir
end

---@param dir string
---@param files table<string, string>
function M.write(dir, files)
  for p, s in pairs(files) do
    local f = dir .. '/' .. p
    vim.fn.mkdir(vim.fs.dirname(f), 'p')
    local h = assert(io.open(f, 'wb'))
    h:write(s)
    h:close()
  end
end

function M.fake_reset()
  local d = vim.env.REDLINE_FAKE_DIR
  vim.fn.delete(d, 'rf')
  vim.fn.mkdir(d .. '/log', 'p')
  vim.fn.mkdir(d .. '/reply', 'p')
end

local n = 0
---@param name string
---@param glob string
---@param out string
---@param code? integer
function M.reply(name, glob, out, code)
  n = n + 1
  local f = ('%s/reply/%s.%03d'):format(vim.env.REDLINE_FAKE_DIR, name, n)
  local h = assert(io.open(f, 'wb'))
  h:write(glob .. '\n' .. (code or 0) .. '\n' .. out)
  h:close()
end

---@class Call
---@field argv string[]
---@field files table<string, string>

---@param name? string
---@return Call[]
function M.calls(name)
  local d = vim.env.REDLINE_FAKE_DIR .. '/log'
  local names = vim.fn.readdir(d)
  table.sort(names)
  local res = {}
  for _, f in ipairs(names) do
    if not f:find('.', 1, true) then
      local s = require('redline.util').read(d .. '/' .. f) or ''
      local argv = vim.split(s, '\0', { plain = true })
      argv[#argv] = nil
      if not name or argv[1] == name then
        local files = {}
        for _, x in ipairs { 'input', 'comments-file', 'body-file' } do
          local p = d .. '/' .. f .. '.' .. x
          if vim.uv.fs_stat(p) then
            files[x] = require('redline.util').read(p)
          end
        end
        res[#res + 1] = { argv = argv, files = files }
      end
    end
  end
  return res
end

---@param dir string
---@param rel string
---@return integer
function M.open(dir, rel)
  vim.cmd.edit(vim.fn.fnameescape(dir .. '/' .. rel))
  return vim.api.nvim_get_current_buf()
end

---@param buf integer
---@param ns integer
---@return vim.api.keyset.get_extmark_item[]
function M.marks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

function M.wipe()
  vim.cmd.stopinsert()
  vim.cmd 'silent! %bwipeout!'
end

return M
