local CommandMenu = require("pi.ui.command_menu").CommandMenu

local root = vim.fs.joinpath(vim.fn.getcwd(), "command-menu-project")
local main_window = vim.api.nvim_get_current_win()
local input_buffer = vim.api.nvim_create_buf(false, true)
local input_window = vim.api.nvim_open_win(input_buffer, true, {
  relative = "win",
  win = main_window,
  row = 8,
  col = 0,
  width = math.max(20, vim.api.nvim_win_get_width(main_window) - 2),
  height = 1,
  style = "minimal",
})
local menu = CommandMenu.new({
  root = root,
  namespace = vim.api.nvim_create_namespace("pi.nvim.command-menu.spec"),
  name_buffer = function(buf, kind, project_root)
    vim.b[buf].pi_kind = kind
    vim.b[buf].pi_root = project_root
  end,
  truncate_display = function(text, width)
    return vim.fn.strcharpart(text, 0, width)
  end,
  commands = function()
    return {
      { name = "zzfixture", description = "Injected command", source = "extension" },
    }
  end,
  main_window = function()
    return main_window
  end,
  input_buffer = function()
    return input_buffer
  end,
  input_window = function()
    return input_window
  end,
})

vim.api.nvim_buf_set_lines(input_buffer, 0, -1, false, { "/zzf" })
vim.wo[input_window].virtualedit = "onemore"
vim.api.nvim_win_set_cursor(input_window, { 1, 4 })
assert(menu:update(), "CommandMenu did not open from its explicit providers")
assert(menu:visible(), "CommandMenu window was not created")
assert(menu.matches[1].word == "/zzfixture", "CommandMenu did not use the injected command source")
assert(menu:accept(), "CommandMenu did not accept its selected match")
assert(
  vim.api.nvim_buf_get_lines(input_buffer, 0, 1, false)[1] == "/zzfixture ",
  "CommandMenu did not update the injected input buffer"
)

local menu_buffer = menu:buffer()
menu:destroy()
menu:destroy()
assert(not vim.api.nvim_buf_is_valid(menu_buffer), "CommandMenu buffer survived destroy")
if vim.api.nvim_win_is_valid(input_window) then
  vim.api.nvim_win_close(input_window, true)
end
if vim.api.nvim_buf_is_valid(input_buffer) then
  vim.api.nvim_buf_delete(input_buffer, { force = true })
end

print("command_menu_spec: ok")
