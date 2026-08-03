if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = 1

local function pi()
  return require("pi")
end

vim.api.nvim_create_user_command("PiChat", function()
  pi().chat()
end, { desc = "Open the Pi chat buffer" })

vim.api.nvim_create_user_command("PiAsk", function(opts)
  pi().ask(opts.args)
end, { nargs = "*", desc = "Send a prompt to Pi" })

vim.api.nvim_create_user_command("PiVisual", function(opts)
  pi().visual(opts.args, opts.line1, opts.line2)
end, { nargs = "*", range = true, desc = "Send a line range to Pi" })

vim.api.nvim_create_user_command("PiBuffer", function(opts)
  pi().buffer(opts.args)
end, { nargs = "*", desc = "Send the current buffer contents to Pi" })

vim.api.nvim_create_user_command("PiAbort", function()
  pi().abort()
end, { desc = "Abort the active Pi operation" })

vim.api.nvim_create_user_command("PiModel", function(opts)
  pi().select_model(nil, opts.args)
end, { nargs = "?", desc = "Select the Pi model" })

vim.api.nvim_create_user_command("PiThinking", function(opts)
  pi().select_thinking_level(nil, opts.args)
end, { nargs = "?", desc = "Select the Pi thinking level" })

vim.api.nvim_create_user_command("PiPermissions", function(opts)
  pi().select_permission_mode(nil, opts.args)
end, {
  nargs = "?",
  complete = function()
    return { "manual", "acceptEdits", "auto", "plan" }
  end,
  desc = "Select the Pi permission mode",
})

vim.api.nvim_create_user_command("PiSettings", function()
  pi().settings()
end, { desc = "Open Pi settings" })

vim.api.nvim_create_user_command("PiLayout", function(opts)
  pi().layout(opts.args)
end, {
  nargs = "?",
  complete = function()
    return { "tab", "float", "right", "bottom" }
  end,
  desc = "Change the Pi workspace layout",
})

vim.api.nvim_create_user_command("PiTree", function()
  pi().tree()
end, { desc = "Browse the Pi session tree" })

vim.api.nvim_create_user_command("PiFork", function()
  pi().fork()
end, { desc = "Fork the Pi session" })

vim.api.nvim_create_user_command("PiClone", function()
  pi().clone()
end, { desc = "Clone the active Pi branch" })

vim.api.nvim_create_user_command("PiCommands", function()
  pi().commands()
end, { desc = "Browse Pi commands" })

vim.api.nvim_create_user_command("PiNew", function()
  pi().new_session()
end, { desc = "Start a new Pi session" })

vim.api.nvim_create_user_command("PiCompact", function(opts)
  pi().compact(opts.args)
end, { nargs = "?", desc = "Compact the current Pi session" })

vim.api.nvim_create_user_command("PiStatus", function()
  pi().status()
end, { desc = "Show Pi session status" })

vim.api.nvim_create_user_command("PiStop", function()
  pi().stop()
end, { desc = "Stop Pi for the current project" })

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("PiNvimBufferTracking", { clear = true }),
  callback = function(event)
    pi().track_buffer(event.buf)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("PiNvimShutdown", { clear = true }),
  callback = function()
    pi().stop_all()
  end,
})
