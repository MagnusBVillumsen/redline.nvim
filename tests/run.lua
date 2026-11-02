-- A small busted-like runner: describe/it/before_each and a few asserts.
local M = {}

local results = { pass = 0, fail = 0, errors = {} }
local stack = {}
local befores = {}

_G.describe = function(name, fn)
  table.insert(stack, name)
  table.insert(befores, false)
  fn()
  table.remove(befores)
  table.remove(stack)
end

_G.before_each = function(fn)
  befores[#befores] = fn
end

_G.it = function(name, fn)
  local full = table.concat(stack, ' › ') .. ' › ' .. name
  for _, b in ipairs(befores) do
    if b then
      b()
    end
  end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    io.stdout:write('  ok   ' .. full .. '\n')
  else
    results.fail = results.fail + 1
    table.insert(results.errors, { full, err })
    io.stdout:write('  FAIL ' .. full .. '\n')
  end
end

_G.eq = function(want, got, msg)
  if not vim.deep_equal(want, got) then
    error(string.format('%sexpected:\n%s\ngot:\n%s', msg and (msg .. '\n') or '', vim.inspect(want), vim.inspect(got)), 2)
  end
end

_G.ok = function(v, msg)
  if not v then
    error(msg or 'expected truthy value', 2)
  end
  return v
end

function M.run()
  local dir = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
  local filter = vim.env.TEST_FILTER
  local files = vim.fn.glob(dir .. '/spec/*_spec.lua', false, true)
  table.sort(files)
  for _, f in ipairs(files) do
    if not filter or f:find(filter, 1, true) then
      io.stdout:write(vim.fs.basename(f) .. '\n')
      local ok, err = xpcall(dofile, debug.traceback, f)
      if not ok then
        results.fail = results.fail + 1
        table.insert(results.errors, { f, err })
      end
    end
  end
  for _, e in ipairs(results.errors) do
    io.stdout:write('\n' .. e[1] .. '\n' .. e[2] .. '\n')
  end
  io.stdout:write(string.format('\n%d passed, %d failed\n', results.pass, results.fail))
  vim.cmd(results.fail == 0 and 'qall!' or 'cquit 1')
end

return M
