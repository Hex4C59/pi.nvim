local Chat = require("pi.ui.chat").Chat
local pi = require("pi")

local root = vim.fn.getcwd()
local submitted = nil
local submitted_root = nil
local function styled_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

local function has_highlight(chunks, highlight)
  for _, chunk in ipairs(chunks or {}) do
    if chunk[2] == highlight then
      return true
    end
  end
  return false
end

local function assert_input_border(config, edge_highlight, corner_highlight, message)
  for index, segment in ipairs(config.border) do
    local expected = index % 2 == 1 and corner_highlight or edge_highlight
    assert(segment[2] == expected, message)
  end
end

local function has_buffer_mapping(buf, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs == lhs then
      return true
    end
  end
  return false
end

local function get_buffer_mapping(buf, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
end

local function has_extmark_highlight(buf, highlight)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if extmark[4] and (extmark[4].hl_group == highlight or extmark[4].line_hl_group == highlight) then
      return true
    end
  end
  return false
end

pi.submit = function(prompt, prompt_root)
  submitted = prompt
  submitted_root = prompt_root
end
pi.abort = function() end

local chat = Chat.new(root)
chat:open()
assert(chat:is_open(), "chat windows were not created")
assert(vim.b.pi_kind == "prompt", "prompt buffer was not focused")
assert(vim.bo.modifiable, "prompt buffer must be editable")
assert(
  vim.api.nvim_buf_get_lines(chat.input_area:buffer(), 0, -1, false)[1] == "",
  "prompt must start without placeholder text"
)
assert(vim.bo[chat.input_area:buffer()].filetype == "pi_prompt", "prompt must use an isolated filetype")
assert(vim.b[chat.input_area:buffer()].completion == false, "external completion must be disabled in the prompt")
assert(vim.bo[chat.input_area:buffer()].complete == "", "native keyword completion must be disabled in the prompt")
assert(
  vim.bo[chat.input_area:buffer()].completefunc == "",
  "slash commands must not use the theme-dependent native popup menu"
)
assert(vim.bo[chat.input_area:buffer()].omnifunc == "", "LSP omnifunc completion must be disabled in the prompt")
assert(vim.bo[chat.input_area:buffer()].tagfunc == "", "tag completion must be disabled in the prompt")
local insert_enter =
  assert(get_buffer_mapping(chat.input_area:buffer(), "i", "<CR>"), "prompt is missing its Insert Enter mapping")
assert(insert_enter.expr == 0, "Insert Enter must not mutate the prompt from an expression mapping")
local insert_down =
  assert(get_buffer_mapping(chat.input_area:buffer(), "i", "<Down>"), "command menu is missing Down navigation")
assert(insert_down.expr == 0, "command navigation must be able to redraw outside expression-map textlock")
assert(has_buffer_mapping(chat.input_area:buffer(), "i", "<Up>"), "command menu is missing Up navigation")
assert(has_buffer_mapping(chat.input_area:buffer(), "i", "<M-p>"), "prompt is missing permission mode shortcut")
assert(has_buffer_mapping(chat.transcript_view.buf, "n", "<LeftMouse>"), "chat canvas is missing its mouse tool toggle")
assert(
  has_buffer_mapping(chat.input_area:buffer(), "i", "<LeftMouse>"),
  "prompt cannot dispatch mouse clicks to the chat"
)
assert(
  chat.input_area:status_window() and vim.api.nvim_win_is_valid(chat.input_area:status_window()),
  "status window was not created"
)
local input_config = vim.api.nvim_win_get_config(chat.input_area:window())
local status_config = vim.api.nvim_win_get_config(chat.input_area:status_window())
assert(input_config.relative == "win" and input_config.win == chat.win, "prompt is not attached to the chat canvas")
assert(status_config.relative == "win" and status_config.win == chat.win, "footer is not attached to the chat canvas")
assert(status_config.focusable == false, "footer must not steal focus")
assert(not vim.wo[chat.win].cursorline, "chat canvas must not show a stale cursor line")
assert(vim.wo[chat.win].breakindent, "wrapped transcript lines must preserve their left edge")
assert(not vim.wo[chat.win].list, "code surface padding must not render as list characters")
assert(input_config.col == 0, "prompt must align with the canvas left edge")
assert(
  input_config.width + 2 == vim.api.nvim_win_get_width(chat.win),
  "prompt frame must align with the canvas right edge"
)
assert(status_config.col == 0 and status_config.width == vim.api.nvim_win_get_width(chat.win), "footer is misaligned")
assert(
  input_config.border[1][1] == "┌"
    and input_config.border[3][1] == "┐"
    and input_config.border[5][1] == "┘"
    and input_config.border[7][1] == "└",
  "prompt border must use square corners"
)
assert(
  input_config.border[2][1] == "─" and input_config.border[6][1] == "─",
  "prompt surface must meet its horizontal edges"
)
assert(
  input_config.border[4][1] == "│" and input_config.border[8][1] == "│",
  "prompt must use vertical side borders"
)
assert(input_config.height == 3, "prompt must reserve balanced vertical padding")
assert(vim.wo[chat.input_area:window()].winbar == " ", "prompt must keep its top padding row")
assert(
  vim.wo[chat.input_area:window()].winhighlight:find("WinBar:PiInputNormal", 1, true),
  "prompt top padding must use the input surface color"
)
assert(
  vim.wo[chat.input_area:window()].winhighlight:find("Cursor:PiInputCursor", 1, true)
    and vim.wo[chat.input_area:window()].winhighlight:find("CursorIM:PiInputCursor", 1, true)
    and vim.wo[chat.input_area:window()].winhighlight:find("lCursor:PiInputCursor", 1, true),
  "prompt cursor and IME preedit text must use the high-contrast input cursor"
)
assert_input_border(input_config, "PiInputBorder", "PiInputCorner", "prompt border surface is inconsistent")
local input_surface = vim.api.nvim_get_hl(0, { name = "PiInputNormal", link = false })
local input_cursor = vim.api.nvim_get_hl(0, { name = "PiInputCursor", link = false })
local input_border = vim.api.nvim_get_hl(0, { name = "PiInputBorder", link = false })
local input_corner = vim.api.nvim_get_hl(0, { name = "PiInputCorner", link = false })
local canvas_surface = vim.api.nvim_get_hl(0, { name = "PiCanvasNormal", link = false })
assert(input_border.bg == input_surface.bg, "gray input surface must fill the straight edge cells")
assert(not input_surface.bold, "prompt text should use normal weight for CJK readability")
assert(
  input_cursor.fg == 0x000000 and input_cursor.bg == 0x000000,
  "IME preedit text must remain black regardless of which cursor color the terminal uses"
)
assert(input_cursor.bold and input_cursor.nocombine, "IME cursor contrast must not inherit a weaker text style")
assert(input_corner.bg == input_surface.bg, "square corner cells must be part of the input surface")
assert(
  vim.api.nvim_strwidth(styled_text(input_config.title)) == input_config.width,
  "prompt top border must span the full frame"
)
assert(
  vim.api.nvim_strwidth(styled_text(input_config.footer)) == input_config.width,
  "prompt bottom border must span the full frame"
)
assert(status_config.height == 1, "footer must remain a single quiet row")
assert(
  vim.wo[chat.input_area:status_window()].winhighlight:find("Normal:PiStatusNormal", 1, true),
  "footer surface is missing"
)
assert(chat:permission_mode() == nil, "confirm UI guessed a mode before Extension status")
assert(chat:_status_text(80)[1]:find("--", 1, true), "unsynchronized permission mode is not visible")

chat:set_input("/smd")
local command_start, command_matches = chat:_command_completion_context()
assert(command_start == 1, "slash completion starts at the wrong input column")
assert(#command_matches == 1 and command_matches[1].word == "/scoped-models", "fuzzy slash matching failed")
assert(command_matches[1].kind == "TUI", "RPC-unavailable Pi command must be identified in completion")
assert(#command_matches[1].match_positions == 3, "fuzzy match positions are missing")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input_area:buffer() })
assert(
  vim.wait(500, function()
    return chat:_command_menu_visible()
  end, 10),
  "custom slash command menu did not open while typing"
)
assert(
  chat.command_menu:window() and vim.api.nvim_win_is_valid(chat.command_menu:window()),
  "command menu window is missing"
)
local command_config = vim.api.nvim_win_get_config(chat.command_menu:window())
assert(command_config.border == nil or command_config.border == "none", "command menu must not render a detached box")
assert(command_config.focusable == false, "command menu must keep focus in the prompt")
assert(
  command_config.col == 0 and command_config.width == vim.api.nvim_win_get_width(chat.win),
  "command menu must align with both canvas edges"
)
assert(
  command_config.row + command_config.height <= vim.api.nvim_win_get_config(chat.input_area:window()).row,
  "command menu must stay above the prompt frame"
)
assert(
  vim.wo[chat.command_menu:window()].winhighlight:find("Normal:PiCommandMenu", 1, true),
  "command menu does not use the Pi canvas surface"
)
local command_surface = vim.api.nvim_get_hl(0, { name = "PiCommandMenu", link = false })
local command_selection = vim.api.nvim_get_hl(0, { name = "PiCommandSelected", link = false })
assert(command_surface.bg == canvas_surface.bg, "command menu must blend into the transcript canvas")
assert(command_selection.bg ~= canvas_surface.bg, "selected command needs a distinct but local surface")
local command_lines = vim.api.nvim_buf_get_lines(chat.command_menu:buffer(), 0, -1, false)
assert(command_lines[1]:find("› /scoped-models", 1, true), "selected fuzzy command is not clearly marked")
assert(vim.api.nvim_strwidth(command_lines[1]) <= command_config.width, "command menu row overflowed its window")
assert(
  has_extmark_highlight(chat.command_menu:buffer(), "PiCommandMatch"),
  "fuzzy matched characters are not highlighted"
)
assert(
  has_extmark_highlight(chat.command_menu:buffer(), "PiCommandSelected"),
  "selected command row is not highlighted"
)
assert(vim.fn.pumvisible() == 0, "native popup menu leaked into the custom command UI")
assert(chat:_accept_command_completion(), "selected command was not accepted")
assert(
  vim.api.nvim_buf_get_lines(chat.input_area:buffer(), 0, 1, false)[1] == "/scoped-models ",
  "accepted command did not replace the fuzzy query"
)
assert(not chat:_command_menu_visible(), "command menu remained open after accepting a command")
chat:set_input("/model")
command_start, command_matches = chat:_command_completion_context()
assert(
  command_start == 1 and command_matches[1].abbr:find("<provider/model>", 1, true),
  "command argument hint is missing"
)
chat:set_input("/mo")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input_area:buffer() })
assert(
  vim.wait(500, function()
    return chat:_command_menu_visible()
  end, 10),
  "ranked fuzzy menu did not reopen"
)
insert_down.callback()
assert(chat.command_menu:selected_index() == 2, "Down did not select the next fuzzy command")
chat:set_input("")

local logo_colors = {}
for index = 1, 4 do
  local color = vim.api.nvim_get_hl(0, { name = "PiWelcomeLogo" .. index, link = false }).fg
  assert(color, "welcome logo color is missing")
  logo_colors[color] = true
end
assert(vim.tbl_count(logo_colors) == 4, "welcome logo must start with four distinct theme colors")
local logo_color_before = vim.api.nvim_get_hl(0, { name = "PiWelcomeLogo1", link = false }).fg
local welcome_before_animation = vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false)
assert(
  vim.wait(1200, function()
    return vim.api.nvim_get_hl(0, { name = "PiWelcomeLogo1", link = false }).fg ~= logo_color_before
  end, 20),
  "welcome logo colors did not rotate"
)
assert(
  vim.deep_equal(welcome_before_animation, vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false)),
  "welcome color animation must not rewrite transcript text"
)

chat:set_path(vim.fs.joinpath(root, "lua", "pi", "init.lua"))
chat:update_permission_mode("manual")
chat:update_state({
  model = { id = "gpt-5.6-sol" },
  thinkingLevel = "high",
  autoCompactionEnabled = true,
})
chat:update_stats({
  tokens = { input = 224000, output = 56000, cacheRead = 6800000 },
  contextUsage = { tokens = 183000, contextWindow = 258000, percent = 71.1 },
  cost = 6.186,
})
local welcome = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(
  vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, 1, false)[1]:find("╭", 1, true),
  "welcome has a top gap"
)
assert(welcome:find("coding agent", 1, true), "empty chat welcome is missing")
assert(welcome:find("gpt-5.6-sol · high", 1, true), "welcome did not refresh the model state")
assert(welcome:find("manual", 1, true), "welcome permission state is missing")
local status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(not status:find(vim.fs.basename(root), 1, true), "project name should be hidden")
assert(status:find("Manual", 1, true), "permission mode is missing from the footer")
assert(not status:find("permissions", 1, true), "permission label should not be repeated in the footer")
local permission_status_groups = {
  vim.api.nvim_get_hl(0, { name = "PiStatusPermissionManual", link = false }),
  vim.api.nvim_get_hl(0, { name = "PiStatusPermissionAcceptEdits", link = false }),
  vim.api.nvim_get_hl(0, { name = "PiStatusPermissionAuto", link = false }),
  vim.api.nvim_get_hl(0, { name = "PiStatusPermissionPlan", link = false }),
}
local permission_status_colors = {}
for _, group in ipairs(permission_status_groups) do
  permission_status_colors[group.fg] = true
end
assert(vim.tbl_count(permission_status_colors) == 4, "permission modes must use distinct footer colors")
assert(not status:find("idle", 1, true), "idle state should be hidden")
assert(status:find("context 71.1%", 1, true), "context usage is missing")
assert(not status:find("$6.186", 1, true), "session cost should not crowd the persistent footer")
assert(not status:find("cache", 1, true), "cache details should not crowd the persistent footer")
local wide_lines = chat:_status_text(120)
local wide_status = table.concat(wide_lines, "\n")
assert(wide_status:find("context 71.1%", 1, true), "wide status is missing context usage")
assert(wide_status:find("Manual", 1, true), "wide status is missing permission mode")
assert(not wide_status:find("permissions", 1, true), "wide status should not repeat the permission label")
assert(#wide_lines == 1, "wide status must remain a single-line layout")
assert(wide_lines[1]:find("gpt-5.6-sol · high", 1, true) == 3, "model state must align with the composer text")
local narrow_lines = chat:_status_text(50)
assert(#narrow_lines == 1, "narrow status must remain a single-line layout")
assert(narrow_lines[1]:find("Manual", 1, true) == 3, "narrow permission mode must align with the composer text")
for _, line in ipairs(narrow_lines) do
  local display_width = vim.api.nvim_strwidth(line)
  assert(display_width <= 50, ("narrow footer overflowed its window (%d): %s"):format(display_width, vim.inspect(line)))
end

chat:add_user("hello")
chat:start_assistant({
  role = "assistant",
  content = {
    { type = "thinking", thinking = "private reasoning" },
    { type = "text", text = "public answer" },
  },
})
chat:end_assistant({
  role = "assistant",
  content = {
    { type = "thinking", thinking = "private reasoning" },
    { type = "text", text = "public answer" },
  },
  stopReason = "stop",
})
local transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("coding agent", 1, true), "welcome disappeared after the conversation started")
assert(
  transcript:find("coding agent", 1, true) < transcript:find(" › hello", 1, true),
  "welcome must remain above the conversation"
)
assert(transcript:find(" hello", 1, true), "user message is missing")
assert(transcript:find(" › hello", 1, true), "user marker is missing")
assert(not transcript:find("YOU", 1, true), "role labels should not be printed in the transcript")
assert(not transcript:find("◆ PI", 1, true), "assistant role labels should not be printed in the transcript")
local public_answer = assert(transcript:find("public answer", 1, true), "completed work lost its public answer")
local thought_summary =
  assert(transcript:find("▸ Thought", 1, true), "completed work did not collapse into a process summary")
assert(public_answer < thought_summary, "completed process summary must appear below the public answer")
assert(not transcript:find("private reasoning", 1, true), "completed work leaked private reasoning")
assert(not transcript:find("##", 1, true), "Markdown headings should not be used as message chrome")
assert(#chat.transcript_view.process_ranges == 1, "completed process summary is not interactive")

chat:toggle_process()
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("private reasoning", 1, true), "completed process details did not expand")
assert(chat.process_expanded, "process detail state did not expand")
chat:toggle_process()
assert(not chat.process_expanded, "process detail state did not return to compact mode")

chat:set_activity("working")
chat:start_tool("tool-1", "bash", { command = "printf hello\nprintf world" })
local multiline_command_lines = vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false)
transcript = table.concat(multiline_command_lines, "\n")
assert(
  transcript:find("Running  printf hello ↵ printf", 1, true),
  "multiline Bash command did not preserve its line-break marker"
)
for index, line in ipairs(multiline_command_lines) do
  assert(
    not line:find("[\r\n]"),
    ("transcript row %d contains an embedded newline: %s"):format(index, vim.inspect(line))
  )
end
local output = {}
for index = 1, 12 do
  table.insert(output, "line " .. index)
end
chat:end_tool("tool-1", { content = { { type = "text", text = table.concat(output, "\n") } } }, false)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("line 1", 1, true), "collapsed tool output should retain a preview")
assert(transcript:find("line 12", 1, true), "collapsed tool output should retain its tail")
assert(not transcript:find("line 6", 1, true), "collapsed tool output showed its middle")
assert(transcript:find("Ctrl-O expand", 1, true), "collapsed tool hint is missing")
chat:toggle_tools()
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("line 6", 1, true), "global tool output did not expand")
chat:toggle_tools()
vim.api.nvim_set_current_win(chat.win)
local tool_range = assert(chat.transcript_view.tool_ranges[1], "tool row range is missing")
vim.api.nvim_win_set_cursor(chat.win, { tool_range.first, 0 })
chat:toggle_tools()
assert(chat.transcript.tools_by_id["tool-1"].expanded == true, "tool under the cursor did not expand")
assert(chat.tools_expanded == false, "single-tool expansion changed the global setting")
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("line 6", 1, true), "single-tool output did not expand")
tool_range = assert(chat.transcript_view.tool_ranges[1], "expanded tool row range is missing")
assert(
  chat:_handle_left_mouse({ winid = chat.win, line = tool_range.first, column = 1 }),
  "mouse click on a tool was not handled"
)
assert(chat.transcript.tools_by_id["tool-1"].expanded == false, "mouse click did not collapse the selected tool")
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(not transcript:find("line 6", 1, true), "mouse-collapsed tool still showed its full output")
assert(
  not chat:_handle_left_mouse({ winid = chat.input_area:window(), line = 1, column = 1 }),
  "mouse click outside the transcript was consumed"
)

chat:set_activity("idle")
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("ran 1 command", 1, true), "settled process summary is missing its command count")
assert(not transcript:find("printf hello", 1, true), "settled process still shows its command")
assert(#chat.transcript_view.tool_ranges == 0, "settled process retained hidden tool ranges")
local process_range = assert(chat.transcript_view.process_ranges[1], "settled process range is missing")
assert(
  chat:_handle_left_mouse({ winid = chat.win, line = process_range.first, column = 1 }),
  "mouse click on the process summary was not handled"
)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("line 6", 1, true), "mouse click did not expand the completed process")
chat:toggle_process()

chat:start_tool("bash-stream", "bash", { command = "fixture stream" })
chat:append_bash_delta("bash-stream", "stream one\n")
chat:append_bash_delta("bash-stream", "stream two\n")
chat:end_bash("bash-stream", {
  output = "truncated final output",
  exitCode = 0,
  truncated = true,
  fullOutputPath = "/tmp/pi-full-output.log",
}, false)
local streamed_bash = chat.transcript.tools_by_id["bash-stream"]
assert(
  require("pi.ui.render").result_text(streamed_bash.result) == "stream one\nstream two\n",
  "truncated Bash response replaced complete streamed output"
)
assert(streamed_bash.result.details.truncated, "Bash truncation metadata was lost")
assert(streamed_bash.result.details.fullOutputPath == "/tmp/pi-full-output.log", "Bash full output path was lost")

chat:start_tool("bash-plain", "bash", { command = "fixture plain" })
chat:end_bash("bash-plain", { output = "plain final output", exitCode = 0 }, false)
assert(
  require("pi.ui.render").result_text(chat.transcript.tools_by_id["bash-plain"].result) == "plain final output",
  "non-streamed Bash response was not displayed"
)
chat.process_expanded = true
chat:_render_transcript()
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(transcript:find("Full output: /tmp/pi-full-output.log", 1, true), "Bash truncation path indicator is missing")
chat.process_expanded = false
chat:_render_transcript()

vim.api.nvim_set_current_win(chat.win)
vim.cmd("normal! Gzb")
local bottom_view = vim.fn.winsaveview()
vim.cmd("normal! 6" .. vim.keycode("<C-e>"))
local overscrolled_view = vim.fn.winsaveview()
if overscrolled_view.topline > bottom_view.topline then
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(chat.win) })
  assert(vim.fn.winsaveview().topline == bottom_view.topline, "transcript retained blank space below its bottom edge")
end

chat:_focus_input()

local frame_before = chat.animation_frame
chat:set_activity("working")
local initial_active_title = vim.inspect(vim.api.nvim_win_get_config(chat.input_area:window()).title)
assert(
  vim.wait(500, function()
    return chat.animation_frame ~= frame_before
  end, 20),
  "working frame animation did not advance"
)
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
local input_title = styled_text(input_config.title)
local input_footer = styled_text(input_config.footer)
assert(vim.inspect(input_config.title) ~= initial_active_title, "working highlight did not move across the frame")
assert(has_highlight(input_config.title, "PiInputBorderPulse"), "working frame is missing its moving highlight")
assert(input_footer:find("Thinking ·", 1, true), "working state is missing from the input frame")
assert(not input_title:find("Thinking", 1, true), "activity label must appear only on the bottom border")
assert(vim.api.nvim_strwidth(input_title) == input_config.width, "animated top border changed width")
assert(vim.api.nvim_strwidth(input_footer) == input_config.width, "animated bottom border changed width")
status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(not status:find("working", 1, true), "working state was duplicated in the footer")
assert(not status:find("Thinking", 1, true), "activity label was duplicated in the footer")

chat:start_assistant({ role = "assistant", content = {} })
chat:update_assistant({ role = "assistant", content = {} }, { type = "thinking_start", contentIndex = 0 })
chat:update_assistant({
  role = "assistant",
  content = { { type = "thinking", thinking = "**Assessing cohesion of Lua modules**" } },
}, {
  type = "thinking_delta",
  contentIndex = 0,
  delta = "**Assessing cohesion of Lua modules**",
})
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
input_footer = styled_text(input_config.footer)
assert(
  input_footer:find("Assessing cohesion of Lua modules", 1, true),
  "reasoning header did not replace the generic activity label"
)
assert(not input_footer:find("Thinking ·", 1, true), "reasoning header was appended to the generic activity label")

chat:update_assistant({
  role = "assistant",
  content = { { type = "thinking", thinking = "**Assessing cohesion of Lua modules**\n\n**Planning test" } },
}, { type = "thinking_delta", contentIndex = 0, delta = "\n\n" })
chat:update_assistant({
  role = "assistant",
  content = { { type = "thinking", thinking = "**Assessing cohesion of Lua modules**\n\n**Planning test" } },
}, { type = "thinking_delta", contentIndex = 0, delta = "**Planning test" })
input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
assert(
  input_footer:find("Assessing cohesion of Lua modules", 1, true),
  "partial next header replaced the current reasoning stage too early"
)
chat:update_assistant({
  role = "assistant",
  content = {
    {
      type = "thinking",
      thinking = "**Assessing cohesion of Lua modules**\n\n**Planning test and format checks**",
    },
  },
}, { type = "thinking_delta", contentIndex = 0, delta = " and format checks**" })
input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
assert(input_footer:find("Planning test and format checks", 1, true), "new reasoning stage did not replace the old one")
assert(not input_footer:find("Assessing cohesion", 1, true), "old reasoning stage accumulated in the input frame")
chat:_render_transcript()
transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view.buf, 0, -1, false), "\n")
assert(not transcript:find("Assessing cohesion", 1, true), "live reasoning header leaked into the transcript")
assert(
  not transcript:find("Planning test and format checks", 1, true),
  "live reasoning stage leaked into the transcript"
)

local live_message = {
  role = "assistant",
  content = {
    {
      type = "thinking",
      thinking = "**Assessing cohesion of Lua modules**\n\n**Planning test and format checks**",
    },
    { type = "text", text = "Live public update" },
  },
}
chat:update_assistant(live_message, { type = "text_delta", contentIndex = 1, delta = "Live public update" })
input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
assert(not input_footer:find("Planning test", 1, true), "reasoning header remained after public output started")
chat:end_assistant(vim.tbl_extend("force", {}, live_message, { stopReason = "stop" }))
chat:set_activity("idle")
assert(chat.animation_timer == nil, "working animation did not stop")
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
assert(not styled_text(input_config.footer):find("Thinking", 1, true), "idle frame retained the activity label")
assert_input_border(input_config, "PiInputBorder", "PiInputCorner", "idle frame did not restore cyan")
status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(not status:find("idle", 1, true), "idle state should disappear from the footer")

chat:set_activity("error")
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
assert(styled_text(input_config.footer):find("Error", 1, true), "error label is missing from the input frame")
assert_input_border(
  input_config,
  "PiInputBorderError",
  "PiInputCornerError",
  "error frame did not switch to its semantic color"
)
assert(chat.animation_timer == nil, "error state must not keep the frame animation alive")
chat:set_activity("idle")

chat:set_queue({ steering = { "one" }, followUp = { "two" } })
status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(status:find("steer 1", 1, true), "steering queue is missing")
assert(status:find("next 1", 1, true), "follow-up queue is missing")

assert(vim.api.nvim_win_get_height(chat.input_area:window()) == 3, "empty prompt should retain vertical padding")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first line", "second line" })
chat.input_area:resize()
assert(vim.api.nvim_win_get_height(chat.input_area:window()) == 4, "multiline prompt did not grow with its padding")
vim.cmd("stopinsert")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
assert(
  vim.wait(1000, function()
    return submitted ~= nil
  end, 10),
  "Enter did not submit the prompt"
)
assert(submitted == "first line\nsecond line", "submitted prompt did not preserve lines")
assert(submitted_root == root, "prompt was not bound to the chat project")
assert(vim.api.nvim_buf_get_lines(chat.input_area:buffer(), 0, -1, false)[1] == "", "prompt was not cleared")

chat:close()
local partial = Chat.new(root .. "/partial-lifecycle")
local partial_input = partial.input_area:ensure_input_buffer()
local partial_command = partial.command_menu:ensure_buffer()
assert(
  partial:owns_buffer(partial_input) and partial:owns_buffer(partial_command),
  "child buffer ownership was not exposed"
)
assert(not partial:owns_buffer(nil), "nil was incorrectly reported as an owned buffer")
partial:destroy()
assert(not vim.api.nvim_buf_is_valid(partial_input), "partial InputArea buffer survived Chat.destroy")
assert(not vim.api.nvim_buf_is_valid(partial_command), "partial CommandMenu buffer survived Chat.destroy")
print("chat_spec: ok")
