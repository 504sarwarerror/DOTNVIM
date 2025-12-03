-- Stack Visualization - Auto-loading plugin entry point
-- This file is automatically loaded by Neovim

-- Prevent loading twice
if vim.g.loaded_stack_visualization then
  return
end
vim.g.loaded_stack_visualization = 1

-- Create user commands
vim.api.nvim_create_user_command('StackViz', function()
  require('stack_visualization').show()
end, {
  desc = 'Show Assembly Stack Visualizer'
})

vim.api.nvim_create_user_command('StackVizRefresh', function()
  require('stack_visualization').refresh()
end, {
  desc = 'Refresh Stack Visualizer'
})

vim.api.nvim_create_user_command('StackVizJump', function()
  require('stack_visualization').jump()
end, {
  desc = 'Jump to variable definition in source'
})

vim.api.nvim_create_user_command('StackVizTooltip', function()
  require('stack_visualization').show_tooltip()
end, {
  desc = 'Show detailed error tooltip'
})

vim.api.nvim_create_user_command('StackVizAutoReloadStart', function()
  require('stack_visualization').start_auto_reload()
end, {
  desc = 'Start auto-reload timer'
})

vim.api.nvim_create_user_command('StackVizAutoReloadStop', function()
  require('stack_visualization').stop_auto_reload()
end, {
  desc = 'Stop auto-reload timer'
})
