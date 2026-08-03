local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat
local permission_mode = require("pi.permission_mode")
local runtime = require("pi.runtime")

local function mapping(buf, lhs, mode)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or "n")) do
    if item.lhs:lower() == lhs:lower() then
      return item.callback
    end
  end
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
local input_win = chat.input_win
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
assert(chat.permission_win and vim.api.nvim_win_is_valid(chat.permission_win), "permission window was not created")
assert(vim.api.nvim_get_current_win() == chat.permission_win, "permission panel did not trap focus")
assert(vim.api.nvim_get_mode().mode == "n", "permission picker did not enter Normal mode")
assert(vim.o.guicursor == "a:PiPermissionCursor", "permission panel did not hide the native cursor")
assert(
  vim.api.nvim_win_get_cursor(chat.permission_win)[2] == 1,
  "permission cursor is not aligned with the selection marker"
)
assert(vim.b[chat.permission_buf].pi_kind == "permission", "permission buffer is missing its UI identity")
local permission_config = vim.api.nvim_win_get_config(chat.permission_win)
local input_config = vim.api.nvim_win_get_config(chat.input_win)
assert(
  permission_config.relative == "win" and permission_config.win == chat.win,
  "permission panel is not attached to the chat canvas"
)
assert(
  permission_config.col == 0 and permission_config.width == vim.api.nvim_win_get_width(chat.win),
  "panel is not full width"
)
assert(input_config.col == 0, "prompt and permission panel do not share the left edge")
assert(input_config.width + 2 == permission_config.width, "prompt and permission panel do not share the right edge")
assert(permission_config.height <= 15, "compact permission panel exceeded its height budget")
assert(
  permission_config.row + permission_config.height <= input_config.row,
  "permission panel overlaps the prompt instead of reserving its own rows"
)
assert(input_config.focusable == false, "prompt remained focusable behind the permission panel")
assert(input_config.hide == false, "prompt was hidden instead of remaining visible below the permission panel")
assert(vim.wo[chat.permission_win].winhighlight:find("Normal:PiPermissionNormal", 1, true), "panel surface is missing")
assert(
  vim.wo[chat.permission_win].winhighlight:find("CursorLine:PiPermissionNormal", 1, true),
  "permission panel inherited the editor cursor-line highlight"
)
assert(
  vim.wo[chat.permission_win].winhighlight:find("Pmenu:PiPermissionNormal", 1, true),
  "permission panel inherited the completion menu highlight"
)
assert(vim.bo[chat.permission_buf].modifiable == false, "permission buffer must remain read-only")
assert(vim.bo[chat.permission_buf].completefunc == "", "permission buffer must disable completion")
assert(vim.bo[chat.permission_buf].omnifunc == "", "permission buffer must disable omnifunc")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionRule"), "permission divider is missing")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionPath"), "working directory path is not highlighted")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionCommandPrompt"), "command prompt is not highlighted")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionShellCommand"), "shell command is not highlighted")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionShellOption"), "shell option is not highlighted")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionShellOperator"), "shell operator is not highlighted")
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionShellString"), "shell string is not highlighted")
assert(
  has_extmark_highlight(chat.permission_buf, "PiPermissionBlockSelected"),
  "selected block action is not highlighted"
)
assert(
  has_line_highlight(chat.permission_buf, "PiPermissionBlockSelected"),
  "selected block action does not highlight the complete row"
)
assert(has_extmark_highlight(chat.permission_buf, "PiPermissionAllow"), "allow action has no success color")
local permission_surface = vim.api.nvim_get_hl(0, { name = "PiPermissionNormal", link = false })
local canvas_surface = vim.api.nvim_get_hl(0, { name = "PiCanvasNormal", link = false })
local block_choice = vim.api.nvim_get_hl(0, { name = "PiPermissionBlock", link = false })
local allow_choice = vim.api.nvim_get_hl(0, { name = "PiPermissionAllow", link = false })
local block_selected = vim.api.nvim_get_hl(0, { name = "PiPermissionBlockSelected", link = false })
assert(permission_surface.bg ~= canvas_surface.bg, "permission UI has no distinct highlighted surface")
assert(block_choice.fg ~= allow_choice.fg, "block and allow actions must use distinct semantic colors")
assert(block_choice.ctermfg ~= allow_choice.ctermfg, "block and allow actions need distinct ANSI colors")
assert(block_selected.bg ~= canvas_surface.bg, "selected action has no visible surface")

local panel = content(chat.permission_buf)
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
for _, line in ipairs(vim.api.nvim_buf_get_lines(chat.permission_buf, 0, -1, false)) do
  assert(
    vim.api.nvim_strwidth(line) <= permission_config.width,
    ("permission row overflowed its window: %s"):format(line)
  )
end

for _, lhs in ipairs({ "<Esc>", "<CR>", "<C-q>", "<Up>", "<Down>", "e", "j", "k", "<C-d>", "<C-u>" }) do
  assert(mapping(chat.permission_buf, lhs), "permission panel is missing mapping " .. lhs)
  assert(mapping(chat.permission_buf, lhs, "i"), "permission panel is missing insert mapping " .. lhs)
end
for _, lhs in ipairs({ "1", "2", "3" }) do
  assert(not mapping(chat.permission_buf, lhs), "permission panel still exposes numeric selection " .. lhs)
  assert(not mapping(chat.permission_buf, lhs, "i"), "permission panel still exposes insert numeric selection " .. lhs)
end
assert(vim.b[chat.permission_buf].pi_permission_owned, "permission panel did not enter Pi-owned input mode")

local compact_height = permission_config.height
mapping(chat.permission_buf, "e")()
permission_config = vim.api.nvim_win_get_config(chat.permission_win)
assert(permission_config.height > compact_height, "expanded permission panel did not reveal more context")
input_config = vim.api.nvim_win_get_config(chat.input_win)
assert(
  permission_config.row + permission_config.height <= input_config.row,
  "expanded permission details overlap the prompt"
)
local offset = chat.permission_area.body_offset
mapping(chat.permission_buf, "<C-d>")()
assert(chat.permission_area.body_offset > offset, "long permission body did not scroll")

input_until("<Down>", function()
  return content(chat.permission_buf):find("❯ Allow once", 1, true) ~= nil
end, "real Down input did not select allow once")
input_until("<Up>", function()
  return content(chat.permission_buf):find("❯ Block", 1, true) ~= nil
end, "real Up input did not select block")
local stolen_j = false
vim.keymap.set({ "n", "i" }, "j", function()
  stolen_j = true
end, { buffer = chat.permission_buf, silent = true, nowait = true })
input_until("j", function()
  return content(chat.permission_buf):find("❯ Allow once", 1, true) ~= nil
end, "real j input did not select allow once")
assert(not stolen_j, "a later plugin mapping stole j from the permission focus trap")
input_until("k", function()
  return content(chat.permission_buf):find("❯ Block", 1, true) ~= nil
end, "real k input did not select block")
input_until("<Down>", function()
  return content(chat.permission_buf):find("❯ Allow once", 1, true) ~= nil
end, "second real Down input did not select allow once")
assert(
  has_extmark_highlight(chat.permission_buf, "PiPermissionAllowSelected"),
  "selected allow action lost its success color"
)
assert(
  has_line_highlight(chat.permission_buf, "PiPermissionAllowSelected"),
  "selected allow action does not highlight the complete row"
)
input_until("<CR>", function()
  return #decisions == 1
end, "real Enter input did not resolve the selected permission")
assert(#decisions == 1 and decisions[1].allowed == "Allow once", "permission panel did not return the raw choice")
assert(not chat.permission_area:active(), "resolved permission remained active")
assert(not chat.permission_win, "resolved permission window was not removed")
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
  return content(chat.permission_buf):find("❯ Allow once", 1, true) ~= nil
end, "session picker did not move to allow once")
input_until("j", function()
  return content(chat.permission_buf):find("❯ Allow for session", 1, true) ~= nil
end, "session picker did not move to allow for session")
assert(
  has_extmark_highlight(chat.permission_buf, "PiPermissionSessionSelected"),
  "selected session action lost its accent color"
)
mapping(chat.permission_buf, "<CR>")()
assert(session_decisions[1] == "Allow for session", "session option was not returned verbatim to the Extension")
chat:select_permission(session_request, function(choice)
  table.insert(session_decisions, choice)
end)
assert(chat.permission_area:active(), "Lua cached an Extension-owned session approval")
mapping(chat.permission_buf, "<Esc>")()
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
  not content(chat.permission_buf):find("Allow for session", 1, true),
  "generic confirm invented a session approval"
)
mapping(chat.permission_buf, "j")()
mapping(chat.permission_buf, "<CR>")()
assert(generic_decision == true, "generic confirmation did not return its boolean choice")

local ctrl_q_decision
chat:confirm({ id = "permission-ctrl-q", method = "confirm", title = "Confirm?", message = "leave" }, function(allowed)
  ctrl_q_decision = allowed
end)
assert(chat.permission_area:active(), "Ctrl-Q test permission did not open")
mapping(chat.permission_buf, "<C-q>")()
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
assert(content(chat.permission_buf):find("1 pending", 1, true), "queued permission count is missing")
mapping(chat.permission_buf, "<Esc>")()
assert(#decisions == 2 and decisions[2].allowed == false, "Escape did not fail closed")
assert(chat.permission_area:active(), "next queued permission was not shown")
assert(content(chat.permission_buf):find("File edit", 1, true), "permission queue advanced to the wrong request")
input_until("j", function()
  return content(chat.permission_buf):find("❯ Allow once", 1, true) ~= nil
end, "queued permission did not move to allow once")
mapping(chat.permission_buf, "<CR>")()
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
