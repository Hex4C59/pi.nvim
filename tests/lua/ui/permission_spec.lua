local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat
local PermissionPanel = require("pi.ui.permission").PermissionPanel
local permission_mode = require("pi.permission_mode")
local runtime = require("pi.runtime")

local function handle(panel, key)
  assert(panel:_handle_key(vim.keycode(key)), "permission panel did not handle " .. key)
end

local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function has_extmark_highlight(buf, highlight)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local details = extmark[4]
    if details and (details.hl_group == highlight or details.line_hl_group == highlight) then
      return true
    end
  end
  return false
end

local function has_line_highlight(buf, highlight)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local details = extmark[4]
    if details and details.line_hl_group == highlight then
      return true
    end
  end
  return false
end

local function input_until(keys, predicate, message)
  vim.api.nvim_feedkeys(vim.keycode(keys), "tx", false)
  assert(vim.wait(500, predicate, 5), message)
end

local direct_actions = { layout = 0, render = 0, close_command_menu = 0 }
local direct_panel = PermissionPanel.new({
  root = vim.fs.joinpath(vim.fn.getcwd(), "direct-permission-project"),
  main_window = function()
    return nil
  end,
  transcript_buffer = function()
    return nil
  end,
  input_window = function()
    return nil
  end,
  actions = {
    layout = function()
      direct_actions.layout = direct_actions.layout + 1
    end,
    render = function()
      direct_actions.render = direct_actions.render + 1
    end,
    close_command_menu = function()
      direct_actions.close_command_menu = direct_actions.close_command_menu + 1
    end,
  },
})
local direct_decision
direct_panel:show({ id = "direct", method = "confirm", title = "Confirm", message = "fixture" }, function(value)
  direct_decision = value
end)
assert(direct_panel:active(), "PermissionPanel could not be constructed without Chat")
assert(direct_actions.close_command_menu == 1, "PermissionPanel did not use its injected close action")
direct_panel:destroy()
direct_panel:destroy()
assert(direct_decision == false, "independent PermissionPanel teardown did not fail closed")

config.setup({
  chat = {
    position = "right",
    width = 0.46,
  },
})

local root = vim.fn.getcwd()
assert(permission_mode.decide == nil, "Lua still owns permission decisions")
assert(permission_mode.is_safe_bash == nil, "Lua still classifies arbitrary Bash text")
local mode_options = permission_mode.options()
assert(mode_options[1].description:find("workspace reads", 1, true), "Manual mode description hides its read boundary")
assert(
  mode_options[2].description:find("outside access", 1, true),
  "Accept Edits description hides outside-workspace confirmation"
)
assert(mode_options[3].description:find("without confirmation", 1, true), "Auto mode description is ambiguous")
assert(mode_options[4].description:find("read/grep/find/ls/todo", 1, true), "Plan mode description hides its tool set")
local chat = Chat.new(root)
chat:open()
local input_win = chat.input_area:window()
local original_guicursor = vim.o.guicursor

local decisions = {}
local long_command = "git status --short && "
  .. "printf '%s\\n' '--- files ---' && "
  .. string.rep("git log -5 --oneline --decorate && ", 24)
  .. "git diff --stat"
chat:select_permission({
  id = "permission-1",
  method = "select",
  title = "Bash command",
  message = long_command,
  options = { "Block", "Allow once", "Allow for session" },
}, function(choice)
  table.insert(decisions, { id = "permission-1", allowed = choice })
end)

assert(chat.permission_area:active(), "permission panel did not become active")
assert(chat.permission_win == nil and chat.permission_buf == nil, "permission UI created a separate window or buffer")
assert(vim.api.nvim_get_current_win() == chat.win, "inline permission UI did not trap focus in the chat content")
assert(vim.api.nvim_get_mode().mode == "n", "permission picker did not enter Normal mode")
assert(vim.o.guicursor == original_guicursor, "inline permission UI changed the native cursor style")
assert(
  vim.api.nvim_win_get_cursor(chat.win)[1] == vim.api.nvim_buf_line_count(chat.transcript_view.buf),
  "inline permission focus is not parked behind the input overlay"
)
local input_config = vim.api.nvim_win_get_config(chat.input_area:window())
assert(input_config.col == 0, "prompt and permission panel do not share the left edge")
assert(input_config.width + 2 == vim.api.nvim_win_get_width(chat.win), "prompt lost the chat content width")
assert(input_config.focusable == false, "prompt remained focusable behind the permission panel")
assert(input_config.hide == false, "prompt was hidden instead of remaining visible below the permission panel")
assert(
  vim.bo[chat.transcript_view.buf].modifiable == false,
  "chat buffer must remain read-only during permission input"
)
assert(has_extmark_highlight(chat.transcript_view.buf, "PiPermissionRule"), "permission divider is missing")
assert(has_extmark_highlight(chat.transcript_view.buf, "PiPermissionPath"), "working directory path is not highlighted")
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionCommandPrompt"),
  "command prompt is not highlighted"
)
assert(has_extmark_highlight(chat.transcript_view.buf, "PiPermissionShellCommand"), "shell command is not highlighted")
assert(has_extmark_highlight(chat.transcript_view.buf, "PiPermissionShellOption"), "shell option is not highlighted")
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionShellOperator"),
  "shell operator is not highlighted"
)
assert(has_extmark_highlight(chat.transcript_view.buf, "PiPermissionShellString"), "shell string is not highlighted")
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionBlockSelected"),
  "selected block action is not highlighted"
)
assert(
  not has_line_highlight(chat.transcript_view.buf, "PiPermissionBlockSelected"),
  "selected block action still highlights the complete row"
)
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionAllow"),
  "unselected allow action is not highlighted"
)
local permission_surface = vim.api.nvim_get_hl(0, { name = "PiPermissionNormal", link = false })
local canvas_surface = vim.api.nvim_get_hl(0, { name = "PiCanvasNormal", link = false })
local block_choice = vim.api.nvim_get_hl(0, { name = "PiPermissionBlock", link = false })
local block_selected = vim.api.nvim_get_hl(0, { name = "PiPermissionBlockSelected", link = false })
assert(permission_surface.bg == canvas_surface.bg, "inline permission UI uses a separate background surface")
assert(block_choice.fg ~= block_selected.fg, "selected action does not change the text color")
assert(block_choice.ctermfg ~= block_selected.ctermfg, "selected action does not change the ANSI text color")
assert(block_selected.bg == nil and block_selected.ctermbg == nil, "selected action still paints a background")

local panel = content(chat.transcript_view.buf)
assert(panel:find("Bash command", 1, true), "permission action type is missing")
assert(panel:find("cwd  ", 1, true), "shell working directory is missing")
assert(panel:find("$ git status", 1, true), "shell command is not displayed as command content")
assert(panel:find("Do you want to proceed?", 1, true), "permission question is missing")
assert(panel:find("❯ Block", 1, true), "safe default is not visibly selected")
assert(panel:find("Allow once", 1, true), "allow-once option is missing")
assert(panel:find("Allow for session", 1, true), "session option is missing")
assert(not panel:find("Permission required", 1, true), "redundant permission heading is still visible")
assert(not panel:find("[ Block ]", 1, true), "permission UI still uses bracket-shaped buttons")
assert(not panel:find("2/2", 1, true), "picker result count leaked into the permission UI")
assert(panel:find("e expand", 1, true), "long permission content cannot be expanded")
local permission_lines = chat.permission_area:transcript_content(vim.api.nvim_win_get_width(chat.win))
for _, line in ipairs(permission_lines) do
  assert(
    vim.api.nvim_strwidth(line) <= vim.api.nvim_win_get_width(chat.win),
    ("permission row overflowed its window: %s"):format(line)
  )
end

local compact_height = #permission_lines
handle(chat.permission_area, "e")
permission_lines = chat.permission_area:transcript_content(vim.api.nvim_win_get_width(chat.win))
assert(#permission_lines > compact_height, "expanded permission panel did not reveal more context")
local offset = chat.permission_area.body_offset
handle(chat.permission_area, "<C-d>")
assert(chat.permission_area.body_offset > offset, "long permission body did not scroll")

input_until("<Down>", function()
  return content(chat.transcript_view.buf):find("❯ Allow once", 1, true) ~= nil
end, "real Down input did not select allow once")
input_until("<Up>", function()
  return content(chat.transcript_view.buf):find("❯ Block", 1, true) ~= nil
end, "real Up input did not select block")
local stolen_j = false
vim.keymap.set({ "n", "i" }, "j", function()
  stolen_j = true
end, { buffer = chat.transcript_view.buf, silent = true, nowait = true })
input_until("j", function()
  return content(chat.transcript_view.buf):find("❯ Allow once", 1, true) ~= nil
end, "real j input did not select allow once")
assert(not stolen_j, "a later plugin mapping stole j from the permission focus trap")
input_until("k", function()
  return content(chat.transcript_view.buf):find("❯ Block", 1, true) ~= nil
end, "real k input did not select block")
input_until("<Down>", function()
  return content(chat.transcript_view.buf):find("❯ Allow once", 1, true) ~= nil
end, "second real Down input did not select allow once")
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionAllowSelected"),
  "selected allow action lost its success color"
)
assert(
  not has_line_highlight(chat.transcript_view.buf, "PiPermissionAllowSelected"),
  "selected allow action still highlights the complete row"
)
input_until("<CR>", function()
  return #decisions == 1
end, "real Enter input did not resolve the selected permission")
assert(#decisions == 1 and decisions[1].allowed == "Allow once", "permission panel did not return the raw choice")
assert(not chat.permission_area:active(), "resolved permission remained active")
assert(
  not content(chat.transcript_view.buf):find("Do you want to proceed?", 1, true),
  "resolved permission remained in the transcript"
)
assert(vim.api.nvim_win_get_config(input_win).focusable == true, "prompt did not regain focusability")
assert(vim.o.guicursor == original_guicursor, "permission panel did not restore the native cursor style")

local session_decisions = {}
local session_request = {
  id = "permission-session-1",
  method = "select",
  title = "Bash command",
  message = "git status",
  options = { "Block", "Allow once", "Allow for session" },
}
chat:select_permission(session_request, function(choice)
  table.insert(session_decisions, choice)
end)
input_until("j", function()
  return content(chat.transcript_view.buf):find("❯ Allow once", 1, true) ~= nil
end, "session picker did not move to allow once")
input_until("j", function()
  return content(chat.transcript_view.buf):find("❯ Allow for session", 1, true) ~= nil
end, "session picker did not move to allow for session")
assert(
  has_extmark_highlight(chat.transcript_view.buf, "PiPermissionSessionSelected"),
  "selected session action lost its accent color"
)
handle(chat.permission_area, "<CR>")
assert(session_decisions[1] == "Allow for session", "session option was not returned verbatim to the Extension")
chat:select_permission(session_request, function(choice)
  table.insert(session_decisions, choice)
end)
assert(chat.permission_area:active(), "Lua cached an Extension-owned session approval")
handle(chat.permission_area, "<Esc>")
assert(session_decisions[2] == "Block", "Escape did not return the safe option")

assert(chat:permission_mode() == nil, "confirm mode guessed a permission mode before Extension status")
assert(chat:permission_mode_label() == "--", "unsynchronized permission mode is not visible")
assert(not chat:update_permission_mode("unsafe"), "invalid Extension mode was accepted")
assert(chat:update_permission_mode("auto"), "valid Extension mode was not mirrored")
assert(chat:permission_mode() == "auto", "Extension mode mirror was not updated")
chat:reset_permission_mode()
assert(chat:permission_mode() == nil, "client reset did not clear the Extension mode mirror")

runtime.chats[root] = chat
local sent_permission_command
local original_send_prompt = runtime.send_prompt
runtime.send_prompt = function(message, _, command_root)
  sent_permission_command = { message, command_root }
end
chat:update_permission_mode("manual")
require("pi.commands.permission").select(root, "auto")
assert(
  vim.deep_equal(sent_permission_command, { "/permissions auto", root }),
  "permission command was not sent to the Extension"
)
assert(chat:permission_mode() == "manual", "Lua updated permission mode before Extension status")
chat:reset_permission_mode()
local original_select = vim.ui.select
vim.ui.select = function(_, _, callback)
  callback({ value = "plan" })
end
require("pi.commands.permission").cycle(root)
vim.ui.select = original_select
runtime.send_prompt = original_send_prompt
assert(sent_permission_command[1] == "/permissions plan", "unknown mode was guessed instead of explicitly selected")

local generic_decision
chat:confirm({ id = "generic-confirm", method = "confirm", title = "Confirm?", message = "generic" }, function(allowed)
  generic_decision = allowed
end)
assert(
  not content(chat.transcript_view.buf):find("Allow for session", 1, true),
  "generic confirm invented a session approval"
)
handle(chat.permission_area, "j")
handle(chat.permission_area, "<CR>")
assert(generic_decision == true, "generic confirmation did not return its boolean choice")

local ctrl_q_decision
chat:confirm({ id = "permission-ctrl-q", method = "confirm", title = "Confirm?", message = "leave" }, function(allowed)
  ctrl_q_decision = allowed
end)
assert(chat.permission_area:active(), "Ctrl-Q test permission did not open")
handle(chat.permission_area, "<C-q>")
assert(ctrl_q_decision == false, "Ctrl-Q must fail closed instead of approving a request")
assert(not chat.permission_area:active(), "Ctrl-Q did not close the permission panel")
assert(vim.api.nvim_get_current_win() == chat.win, "Ctrl-Q did not return focus to the Pi canvas")
assert(vim.api.nvim_get_mode().mode == "n", "Ctrl-Q did not return Neovim to Normal mode")

chat:confirm(
  { id = "permission-2", method = "confirm", title = "Allow model file write?", message = "a.txt\n12 bytes" },
  function(allowed)
    table.insert(decisions, { id = "permission-2", allowed = allowed })
  end
)
chat:confirm(
  { id = "permission-3", method = "confirm", title = "Allow model file edit?", message = "b.txt\n2 edits" },
  function(allowed)
    table.insert(decisions, { id = "permission-3", allowed = allowed })
  end
)
assert(content(chat.transcript_view.buf):find("1 pending", 1, true), "queued permission count is missing")
handle(chat.permission_area, "<Esc>")
assert(#decisions == 2 and decisions[2].allowed == false, "Escape did not fail closed")
assert(chat.permission_area:active(), "next queued permission was not shown")
assert(content(chat.transcript_view.buf):find("File edit", 1, true), "permission queue advanced to the wrong request")
input_until("j", function()
  return content(chat.transcript_view.buf):find("❯ Allow once", 1, true) ~= nil
end, "queued permission did not move to allow once")
handle(chat.permission_area, "<CR>")
assert(#decisions == 3 and decisions[3].allowed == true, "direct allow shortcut returned the wrong decision")

chat:confirm({ id = "permission-4", method = "confirm", title = "Confirm?", message = "one" }, function(allowed)
  table.insert(decisions, { id = "permission-4", allowed = allowed })
end)
chat:confirm({ id = "permission-5", method = "confirm", title = "Confirm?", message = "two" }, function(allowed)
  table.insert(decisions, { id = "permission-5", allowed = allowed })
end)
chat:close()
assert(#decisions == 5, "closing the chat did not resolve every pending permission")
assert(decisions[4].allowed == false and decisions[5].allowed == false, "closing the chat did not fail closed")
assert(vim.o.guicursor == original_guicursor, "closing the chat did not restore the native cursor style")

print("permission_spec: ok")
