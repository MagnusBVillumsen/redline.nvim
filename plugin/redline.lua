if vim.g.loaded_redline then
  return
end
vim.g.loaded_redline = true

vim.api.nvim_create_user_command('Redline', function(opts)
  require('redline').command(opts)
end, {
  nargs = '*',
  range = true,
  bang = true,
  desc = 'redline.nvim',
  complete = function(lead, line)
    return require('redline').complete(lead, line)
  end,
})
