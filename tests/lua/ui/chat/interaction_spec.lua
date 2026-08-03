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

local chat = Chat.new(root, {
  submit = function(prompt)
    submitted = prompt
    submitted_root = root
  end,
  abort = function() end,
})
chat:open()
assert(vim.b.pi_kind == "prompt", "prompt buffer was not focused")
assert(has_buffer_mapping(chat.transcript_view.buf, "n", "<LeftMouse>"), "chat canvas is missing its mouse tool toggle")

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
chat:set_input("")

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
