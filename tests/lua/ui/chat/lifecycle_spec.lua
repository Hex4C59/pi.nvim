local Chat = require("pi.ui.chat").Chat

local root = vim.fs.joinpath(vim.fn.getcwd(), "lifecycle-project")
local chat = Chat.new(root)
local decisions = {}

chat:open(false)
assert(chat:is_open(), "Chat did not open its complete window set")
chat:confirm(
  { id = "lifecycle-permission", method = "confirm", title = "Confirm", message = "fixture" },
  function(value)
    table.insert(decisions, value)
  end
)
chat:close()
assert(not chat:is_open(), "Chat remained open after close")
assert(decisions[1] == false, "closing Chat did not fail closed for an active permission")

chat:open(false)
assert(chat:is_open(), "Chat could not reopen after close")
local main_window = chat.win
chat:destroy()
assert(not vim.api.nvim_win_is_valid(main_window), "Chat.destroy left its main window alive")
chat:destroy()

local partial = Chat.new(root .. "-partial")
local partial_input = partial.input_area:ensure_input_buffer()
local partial_command = partial.command_menu:ensure_buffer()
assert(
  partial:owns_buffer(partial_input) and partial:owns_buffer(partial_command),
  "child buffer ownership was not exposed"
)
assert(not partial:owns_buffer(nil), "nil was incorrectly reported as an owned buffer")
partial:destroy()
partial:destroy()
assert(not vim.api.nvim_buf_is_valid(partial_input), "partial InputArea buffer survived Chat.destroy")
assert(not vim.api.nvim_buf_is_valid(partial_command), "partial CommandMenu buffer survived Chat.destroy")

print("chat_lifecycle_spec: ok")
