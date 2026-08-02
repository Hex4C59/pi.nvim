local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

config.setup({
  chat = {
    position = "tab",
    float = { width = 0.8, height = 0.8, border = "rounded" },
  },
})

local chat = Chat.new(vim.fn.getcwd())
chat:open(false)
assert(vim.api.nvim_win_get_config(chat.win).relative == "", "tab layout must use a normal window")
assert(vim.api.nvim_tabpage_get_number(0) == 2, "tab layout did not create a dedicated tab")

chat:set_position("float")
local main = vim.api.nvim_win_get_config(chat.win)
local input = vim.api.nvim_win_get_config(chat.input_win)
local footer = vim.api.nvim_win_get_config(chat.status_win)
assert(main.relative == "editor", "float layout did not create an editor-relative canvas")
assert(input.relative == "win" and input.win == chat.win, "prompt lost its canvas parent in float layout")
assert(footer.relative == "win" and footer.win == chat.win, "footer lost its canvas parent in float layout")

chat:set_position("right")
main = vim.api.nvim_win_get_config(chat.win)
assert(main.relative == "" and main.split == "right", "right layout did not create a right split")

chat:set_position("bottom")
main = vim.api.nvim_win_get_config(chat.win)
assert(main.relative == "" and main.split == "below", "bottom layout did not create a bottom split")

chat:close()
print("layout_spec: ok")
