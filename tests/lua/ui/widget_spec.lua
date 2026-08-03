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
assert(
  chat.widget_area:window("aboveEditor") == nil and chat.widget_area:buffer("aboveEditor") == nil,
  "todo must not create a separate widget window or buffer"
)
local transcript_lines = vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false)
local transcript = table.concat(transcript_lines, "\n")
assert(transcript:find("Implement widget support", 1, true), "todo was not rendered in the chat transcript")
assert(vim.tbl_contains(transcript_lines, "• Plan · 1/3 complete"), "todo title is not a transcript history row")
assert(vim.tbl_contains(transcript_lines, "  └ ◐ #2 Implement widget support"), "first todo lost its branch indent")
assert(vim.tbl_contains(transcript_lines, "    ○ #3 Run tests"), "pending todo lost its transcript indent")
assert(vim.tbl_contains(transcript_lines, "    ✓ #1 Inspect Pi API"), "completed todo lost its transcript indent")
assert(has_highlight(chat.transcript_view.buf, "PiPlanTitle"), "todo title is not highlighted")
assert(has_highlight(chat.transcript_view.buf, "PiPlanActive"), "active todo is not highlighted")
assert(has_highlight(chat.transcript_view.buf, "PiPlanPending"), "pending todo is not highlighted")
assert(has_highlight(chat.transcript_view.buf, "PiPlanCompleted"), "completed todo is not highlighted")
for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(chat.transcript_view.buf, -1, 0, -1, { details = true })) do
  local details = extmark[4] or {}
  if type(details.hl_group) == "string" and vim.startswith(details.hl_group, "PiPlan") then
    assert(details.line_hl_group == nil, "inline todo still paints a separate full-width surface")
  end
end
assert(
  vim.api.nvim_get_hl(0, { name = "PiPlanTitle", link = false }).bg == nil,
  "inline todo title has a panel background"
)
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  assert(vim.b[bufnr].pi_kind ~= "widget", "todo unexpectedly allocated a widget buffer")
end

chat:set_widget("pi.todo", {
  "Plan · 0/1 complete",
  "◐ #1 检查中文任务换行仍与内容边界对齐",
}, "aboveEditor")
local wrapped_lines, wrapped_marks = chat.widget_area:transcript_content(24)
assert(wrapped_lines[2]:find("^  └ ◐ "), "wrapped todo lost its first-line transcript indent")
assert(wrapped_lines[3]:find("^      "), "wrapped todo continuation is not aligned below its text")
for _, line in ipairs(wrapped_lines) do
  assert(vim.fn.strdisplaywidth(line) <= 24, "wrapped todo crossed the transcript's right edge")
end
for _, mark in ipairs(wrapped_marks) do
  assert(mark.line_highlight == nil, "wrapped todo requested a full-line background")
end

chat:set_widget("pi.todo", {
  "Plan · 0/6 complete",
  "◐ #1 First",
  "○ #2 Second",
  "○ #3 Third",
  "○ #4 Fourth",
  "○ #5 Fifth",
  "○ #6 Sixth",
}, "aboveEditor")
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("… 4 more", 1, true), "inline todo did not respect chat.max_widget_height")
assert(not transcript:find("#6 Sixth", 1, true), "inline todo leaked rows beyond its height limit")
assert(not transcript:find("Implement widget support", 1, true), "todo update retained stale transcript rows")
assert(has_highlight(chat.transcript_view.buf, "PiPlanMuted"), "todo overflow summary is not muted")
assert(not chat:set_widget("invalid", { "ok", false }, "aboveEditor"), "non-string widget lines were accepted")

chat:set_widget("pi.todo", nil)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(not transcript:find("Plan ·", 1, true), "cleared todo retained stale transcript text")
chat:set_widget("fixture.above", { "Above the editor" }, "aboveEditor")
assert(
  chat.widget_area:window("aboveEditor") and vim.api.nvim_win_is_valid(chat.widget_area:window("aboveEditor")),
  "generic above-editor widget lost its window"
)
assert(
  chat.widget_area:buffer("aboveEditor") and vim.api.nvim_buf_is_valid(chat.widget_area:buffer("aboveEditor")),
  "generic above-editor widget lost its buffer"
)
assert(vim.b[chat.widget_area:buffer("aboveEditor")].pi_kind == "widget", "generic widget buffer kind is missing")
chat:set_widget("fixture.above", nil)
chat:set_widget("fixture.below", { "Below the editor" }, "belowEditor")
local below_win = chat.widget_area:window("belowEditor")
assert(below_win and vim.api.nvim_win_is_valid(below_win), "below-editor widget window was not created")
local below_config = vim.api.nvim_win_get_config(below_win)
local input = vim.api.nvim_win_get_config(chat.input_area:window())
local footer = vim.api.nvim_win_get_config(chat.input_area:status_window())
assert(
  below_config.col == 0 and below_config.width == vim.api.nvim_win_get_width(chat.win),
  "below-editor widget is not full width"
)
assert(below_config.row >= input.row + input.height + 2, "below-editor widget overlaps the prompt frame")
assert(below_config.row + below_config.height <= footer.row, "below-editor widget overlaps the footer")

chat:set_widget("fixture.below", nil)
chat:set_widget("pi.todo", { "Plan · 0/1 complete", "○ #1 Stay visible" }, "aboveEditor")
chat:confirm({ id = "widget-permission", method = "confirm", title = "Confirm", message = "command" }, function() end)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("Stay visible", 1, true), "todo disappeared while the permission surface was open")
chat.permission_area:_resolve(false)
assert(chat.widget_area:window("aboveEditor") == nil, "todo created a widget window after permission closed")

chat:set_input("/mo")
assert(chat:_update_command_menu(), "command menu did not open for widget overlap test")
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("Stay visible", 1, true), "todo disappeared while slash-command completion was open")
chat:_close_command_menu()
assert(chat.widget_area:window("aboveEditor") == nil, "todo created a widget window after command completion closed")

chat:clear_widgets()
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(not transcript:find("Stay visible", 1, true), "cleared todo remained in the transcript")
assert(
  chat.widget_area:window("aboveEditor") == nil and next(chat.widget_area.widgets) == nil,
  "widget state did not clear"
)
chat:close()
print("widget_spec: ok")
