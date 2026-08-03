local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local function has_highlight(buf, name)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if mark[4] and (mark[4].hl_group == name or mark[4].line_hl_group == name) then
      return true
    end
  end
  return false
end

config.setup({
  chat = {
    position = "tab",
    max_widget_height = 4,
    float = { width = 0.8, height = 0.8, border = "rounded" },
  },
})

local chat = Chat.new(vim.fn.getcwd())
chat:open(false)
assert(
  chat:set_widget("pi.todo", {
    "Plan · 1/3 complete",
    "◐ #2 Implement widget support",
    "○ #3 Run tests",
    "✓ #1 Inspect Pi API",
  }, "aboveEditor"),
  "valid todo widget was rejected"
)
assert(chat.widget_win and vim.api.nvim_win_is_valid(chat.widget_win), "above-editor widget window was not created")
assert(chat.widget_buf and vim.api.nvim_buf_is_valid(chat.widget_buf), "above-editor widget buffer was not created")
assert(vim.b[chat.widget_buf].pi_kind == "widget", "widget buffer kind is missing")
assert(vim.bo[chat.widget_buf].modifiable == false, "widget buffer must stay read-only")
local widget = vim.api.nvim_win_get_config(chat.widget_win)
local input = vim.api.nvim_win_get_config(chat.input_win)
assert(widget.relative == "win" and widget.win == chat.win, "widget is not attached to the chat canvas")
assert(widget.focusable == false, "widget must not steal prompt focus")
assert(widget.col == 0 and widget.width == vim.api.nvim_win_get_width(chat.win), "widget is not full width")
assert(widget.row + widget.height <= input.row, "above-editor widget overlaps the prompt")
assert(has_highlight(chat.widget_buf, "PiWidgetTitle"), "widget title is not highlighted")
assert(has_highlight(chat.widget_buf, "PiWidgetActive"), "active todo is not highlighted")
assert(has_highlight(chat.widget_buf, "PiWidgetPending"), "pending todo is not highlighted")
assert(has_highlight(chat.widget_buf, "PiWidgetCompleted"), "completed todo is not highlighted")

chat:set_widget("pi.todo", {
  "Plan · 0/6 complete",
  "◐ #1 First",
  "○ #2 Second",
  "○ #3 Third",
  "○ #4 Fourth",
  "○ #5 Fifth",
  "○ #6 Sixth",
}, "aboveEditor")
widget = vim.api.nvim_win_get_config(chat.widget_win)
local lines = vim.api.nvim_buf_get_lines(chat.widget_buf, 0, -1, false)
assert(widget.height == 4 and #lines == 4, "widget did not respect chat.max_widget_height")
assert(lines[4]:find("more", 1, true), "bounded widget did not report omitted rows")
assert(has_highlight(chat.widget_buf, "PiWidgetMuted"), "widget overflow summary is not muted")
assert(not chat:set_widget("invalid", { "ok", false }, "aboveEditor"), "non-string widget lines were accepted")

chat:set_widget("pi.todo", nil)
assert(chat.widget_win == nil, "cleared above-editor widget window remained open")
assert(vim.api.nvim_buf_get_lines(chat.widget_buf, 0, -1, false)[1] == "", "cleared widget retained stale text")
chat:set_widget("fixture.below", { "Below the editor" }, "belowEditor")
local below = chat.widget_area.slots.belowEditor
assert(below.win and vim.api.nvim_win_is_valid(below.win), "below-editor widget window was not created")
local below_config = vim.api.nvim_win_get_config(below.win)
input = vim.api.nvim_win_get_config(chat.input_win)
local footer = vim.api.nvim_win_get_config(chat.status_win)
assert(
  below_config.col == 0 and below_config.width == vim.api.nvim_win_get_width(chat.win),
  "below-editor widget is not full width"
)
assert(below_config.row >= input.row + input.height + 2, "below-editor widget overlaps the prompt frame")
assert(below_config.row + below_config.height <= footer.row, "below-editor widget overlaps the footer")

chat:set_widget("fixture.below", nil)
chat:set_widget("pi.todo", { "Plan · 0/1 complete", "○ #1 Stay visible" }, "aboveEditor")
chat:confirm({ id = "widget-permission", method = "confirm", title = "Confirm", message = "command" }, function() end)
assert(chat.widget_win == nil, "widget must yield to the permission surface")
chat.permission_area:_resolve(false)
assert(chat.widget_win and vim.api.nvim_win_is_valid(chat.widget_win), "widget did not return after permission closed")

chat:set_input("/mo")
assert(chat:_update_command_menu(), "command menu did not open for widget overlap test")
assert(chat.widget_win == nil, "widget must yield to slash-command completion")
chat:_close_command_menu()
assert(
  chat.widget_win and vim.api.nvim_win_is_valid(chat.widget_win),
  "widget did not return after command menu closed"
)

chat:clear_widgets()
assert(chat.widget_win == nil and next(chat.widget_area.widgets) == nil, "widget state did not clear")
chat:close()
print("widget_spec: ok")
