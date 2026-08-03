local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local function assert_horizontal_alignment(chat, label)
  local width = vim.api.nvim_win_get_width(chat.win)
  local input = vim.api.nvim_win_get_config(chat.input_area:window())
  local footer = vim.api.nvim_win_get_config(chat.input_area:status_window())
  assert(input.col == 0, label .. " prompt is not aligned with the left edge")
  assert(input.width + 2 == width, label .. " prompt is not aligned with the right edge")
  assert(footer.col == 0 and footer.width == width, label .. " footer is not aligned with the canvas")
  assert(
    input.border[4][1] == "│" and input.border[8][1] == "│",
    label .. " prompt does not use vertical side borders"
  )
end

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
assert_horizontal_alignment(chat, "tab")

chat:set_position("float")
local main = vim.api.nvim_win_get_config(chat.win)
local input = vim.api.nvim_win_get_config(chat.input_area:window())
local footer = vim.api.nvim_win_get_config(chat.input_area:status_window())
assert(main.relative == "editor", "float layout did not create an editor-relative canvas")
assert(input.relative == "win" and input.win == chat.win, "prompt lost its canvas parent in float layout")
assert(footer.relative == "win" and footer.win == chat.win, "footer lost its canvas parent in float layout")
assert_horizontal_alignment(chat, "float")
chat:set_title("Focused task\nignored")
main = vim.api.nvim_win_get_config(chat.win)
assert(chat.title == "Focused task", "Extension title was not sanitized and retained")
assert(vim.b[chat.transcript_view.buf].pi_title == "Focused task", "Extension title was not exposed on the Chat buffer")
assert(vim.inspect(main.title):find("Focused task", 1, true), "Extension title was not rendered on the floating Chat")

chat:set_position("right")
main = vim.api.nvim_win_get_config(chat.win)
assert(main.relative == "" and main.split == "right", "right layout did not create a right split")
assert_horizontal_alignment(chat, "right")

chat:set_position("bottom")
main = vim.api.nvim_win_get_config(chat.win)
assert(main.relative == "" and main.split == "below", "bottom layout did not create a bottom split")
assert_horizontal_alignment(chat, "bottom")
local bottom_height = vim.api.nvim_win_get_height(chat.win)
chat:confirm({
  id = "layout-permission",
  method = "confirm",
  title = "Allow model Bash command?",
  message = "git status --short --branch && git log -5 --oneline",
}, function() end)
input = vim.api.nvim_win_get_config(chat.input_area:window())
assert(vim.api.nvim_win_get_height(chat.win) >= 16, "permission UI did not expand the short bottom split")
assert(chat.permission_win == nil and chat.permission_buf == nil, "permission UI created a separate window or buffer")
local permission_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false)) do
  if line:find("Do you want to proceed?", 1, true) then
    permission_row = row
    break
  end
end
assert(permission_row, "inline permission question is missing from the chat content")
local permission_position = vim.fn.screenpos(chat.win, permission_row, 1)
local chat_position = vim.fn.win_screenpos(chat.win)
local relative_permission_row = permission_position.row - chat_position[1]
assert(permission_position.row > 0, "inline permission question is outside the visible chat content")
assert(relative_permission_row < input.row, "inline permission UI overlaps the prompt in the bottom layout")
assert(input.height == 3, "inactive prompt did not collapse to its minimum height during confirmation")
chat.permission_area:_resolve(false)
assert(
  not table
    .concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
    :find("Do you want to proceed?", 1, true),
  "resolved permission remained in the chat content"
)
assert(
  vim.api.nvim_win_get_height(chat.win) == bottom_height,
  "bottom split height was not restored after confirmation"
)

chat:destroy()
print("chat_shell_spec: ok")
