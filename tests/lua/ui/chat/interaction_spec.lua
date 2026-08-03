local Chat = require("pi.ui.chat").Chat

local root = vim.fn.getcwd()
local submitted = nil
local submitted_root = nil

local function has_buffer_mapping(buf, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs == lhs then
      return true
    end
  end
  return false
end

local function has_extmark_highlight(buf, highlight)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if extmark[4] and (extmark[4].hl_group == highlight or extmark[4].line_hl_group == highlight) then
      return true
    end
  end
  return false
end

local chat = Chat.new(root, {
  submit = function(prompt)
    submitted = prompt
    submitted_root = root
  end,
  abort = function() end,
})
chat:open()
assert(chat:is_open(), "chat windows were not created")
assert(vim.b.pi_kind == "prompt", "prompt buffer was not focused")
assert(has_buffer_mapping(chat.transcript_view.buf, "n", "<LeftMouse>"), "chat canvas is missing its mouse tool toggle")
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
assert(input_config.height == 3, "prompt must reserve balanced vertical padding")
assert(status_config.height == 1, "footer must remain a single quiet row")
assert(chat:permission_mode() == nil, "confirm UI guessed a mode before Extension status")

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
local canvas_surface = vim.api.nvim_get_hl(0, { name = "PiCanvasNormal", link = false })
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
assert(chat:_select_command(1), "command menu did not accept downward selection")
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
assert(status:find("context 71.1%", 1, true), "context usage is missing")

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
assert(submitted_root == root, "prompt was not bound to the chat project")

chat:destroy()
print("chat_interaction_spec: ok")
