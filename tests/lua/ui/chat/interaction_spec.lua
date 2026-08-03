local Chat = require("pi.ui.chat").Chat

local root = vim.fs.joinpath(vim.fn.getcwd(), "input-wiring-project")
local submitted
local submitted_root

local chat = Chat.new(root, {
  submit = function(prompt)
    submitted = prompt
    submitted_root = root
  end,
})
chat:open()
assert(vim.b.pi_kind == "prompt", "prompt buffer was not focused")

chat:set_input("/smd")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input_area:buffer() })
assert(
  vim.wait(500, function()
    return chat:_command_menu_visible()
  end, 10),
  "custom slash command menu did not open while typing"
)
assert(chat:_accept_command_completion(), "selected command was not accepted")
assert(
  vim.api.nvim_buf_get_lines(chat.input_area:buffer(), 0, 1, false)[1] == "/scoped-models ",
  "accepted command did not replace the fuzzy query"
)
assert(not chat:_command_menu_visible(), "command menu remained open after accepting a command")

chat:set_input("/mo")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input_area:buffer() })
assert(
  vim.wait(500, function()
    return chat:_command_menu_visible()
  end, 10),
  "ranked fuzzy menu did not reopen"
)
local insert_down = vim.api.nvim_buf_call(chat.input_area:buffer(), function()
  return vim.fn.maparg("<Down>", "i", false, true)
end)
assert(type(insert_down.callback) == "function", "InputArea did not wire command-menu navigation")
insert_down.callback()
assert(chat.command_menu:selected_index() == 2, "Down did not select the next fuzzy command")

chat:set_input("root-bound prompt")
vim.cmd("stopinsert")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
assert(
  vim.wait(1000, function()
    return submitted ~= nil
  end, 10),
  "Enter did not submit the prompt"
)
assert(submitted == "root-bound prompt", "Chat submission boundary changed the prompt")
assert(submitted_root == root, "prompt was not bound to the Chat project")

chat:destroy()
print("chat_interaction_spec: ok")
