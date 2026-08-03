local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local function assert_horizontal_alignment(chat, label)
  local width = vim.api.nvim_win_get_width(chat.win)
  local input = vim.api.nvim_win_get_config(chat.input_win)
  local footer = vim.api.nvim_win_get_config(chat.status_win)
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
local input = vim.api.nvim_win_get_config(chat.input_win)
local footer = vim.api.nvim_win_get_config(chat.status_win)
assert(main.relative == "editor", "float layout did not create an editor-relative canvas")
assert(input.relative == "win" and input.win == chat.win, "prompt lost its canvas parent in float layout")
assert(footer.relative == "win" and footer.win == chat.win, "footer lost its canvas parent in float layout")
assert_horizontal_alignment(chat, "float")
chat:set_title("Focused task\nignored")
main = vim.api.nvim_win_get_config(chat.win)
assert(chat.title == "Focused task", "Extension title was not sanitized and retained")
assert(vim.b[chat.buf].pi_title == "Focused task", "Extension title was not exposed on the Chat buffer")
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
local permission = vim.api.nvim_win_get_config(chat.permission_win)
input = vim.api.nvim_win_get_config(chat.input_win)
assert(vim.api.nvim_win_get_height(chat.win) >= 16, "permission UI did not expand the short bottom split")
assert(permission.height >= 10, "permission UI did not reserve rows for both command context and choices")
assert(permission.col == 0 and permission.width == vim.api.nvim_win_get_width(chat.win), "permission UI is misaligned")
assert(permission.row + permission.height <= input.row, "permission UI overlaps the prompt in the bottom layout")
assert(input.height == 3, "inactive prompt did not collapse to its minimum height during confirmation")
chat.permission_area:_resolve(false)
assert(
  vim.api.nvim_win_get_height(chat.win) == bottom_height,
  "bottom split height was not restored after confirmation"
)

chat:close()
print("layout_spec: ok")
