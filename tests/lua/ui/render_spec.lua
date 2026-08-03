local renderer = require("pi.ui.render")

local lua_parser_available = pcall(function()
  local parser = vim.treesitter.get_string_parser("local value = true", "lua")
  assert(parser:parse()[1])
  assert(vim.treesitter.query.get("lua", "highlights"))
end)

local bash_lines = {}
for index = 1, 12 do
  table.insert(bash_lines, "line " .. index)
end

local items = {
  { type = "user", text = "Review this" },
  {
    type = "assistant",
    duration_ms = 6100,
    message = {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "reasoning" },
        {
          type = "text",
          text = "# Result\n\n**Overview**\n\nRead [lua/example.lua](/tmp/lua/example.lua), use `ready`, then **verify**.\n\n- first item\n\n> quoted\n\n```lua\nlocal value = true\n```",
        },
      },
    },
  },
  {
    type = "tool",
    id = "edit-1",
    name = "edit",
    state = "done",
    duration_ms = 12000,
    args = {
      path = "lua/example.lua",
      oldText = "local old = true",
      newText = "local new = true",
    },
    result = { content = { { type = "text", text = "Updated lua/example.lua" } } },
  },
  {
    type = "tool",
    id = "bash-1",
    name = "bash",
    state = "done",
    args = { command = "printf hello" },
    result = { content = { { type = "text", text = table.concat(bash_lines, "\n") } } },
  },
  {
    type = "tool",
    id = "read-1",
    name = "read",
    state = "done",
    args = { path = "README.md", offset = 1 },
    result = { content = { { type = "text", text = "<p>raw file content</p>\nsecond line" } } },
  },
}

local lines, marks, tool_ranges = renderer.render(items, {
  hide_thinking = true,
  tools_expanded = false,
  width = 80,
})
local text = table.concat(lines, "\n")
assert(lines[1] ~= "  PI", "legacy transcript PI header is still present")
assert(text:find("Review this", 1, true), "user component is missing")
assert(text:find(" › Review this", 1, true), "user text must start with the structural marker")
assert(not text:find("YOU", 1, true), "role labels should not be printed in the transcript")
assert(text:find("Thought for 6.1s", 1, true), "thinking duration is missing from the assistant status")
assert(not text:find("+ Thought", 1, true), "thinking duration still occupies a separate row")
assert(not text:find("reasoning", 1, true), "thinking should be collapsed")
assert(not text:find("◆ PI", 1, true), "assistant role labels should not be printed in the transcript")
assert(
  text:find("Thought for 6.1s", 1, true) < text:find(" Result", 1, true),
  "thinking status must precede the final response"
)
assert(text:find(" Result", 1, true), "Markdown heading was not rendered")
assert(not text:find("# Result", 1, true), "Markdown heading marker was not removed")
assert(text:find(" Overview", 1, true), "strong section heading was not rendered")
assert(not text:find("**Overview**", 1, true), "strong section marker leaked into the transcript")
assert(
  text:find("Read lua/example.lua, use ready, then verify.", 1, true),
  "inline Markdown was not reduced to readable text"
)
assert(not text:find("/tmp/lua/example.lua", 1, true), "Markdown link target leaked into the transcript")
assert(text:find("- first item", 1, true), "Markdown list item is missing")
assert(text:find(" │ quoted", 1, true), "Markdown quote was not rendered")
assert(text:find(" local value = true", 1, true), "code block is missing")
local code_row
for row, line in ipairs(lines) do
  if line:find("local value = true", 1, true) then
    code_row = row
    break
  end
end
assert(code_row, "code row is missing")
assert(vim.fn.strdisplaywidth(lines[code_row]) == 79, "code surface lost its right margin")

local code_surface
for _, mark in ipairs(marks) do
  if mark.row == code_row - 1 and mark.highlight == "PiCodeBg" then
    code_surface = mark
  end
  assert(mark.line_highlight ~= "PiCodeBg", "code surface still uses full-line highlighting")
end
assert(code_surface and code_surface.start_col == 1, "code surface lost its left margin")
assert(text:find("Actions", 1, true), "tool group label is missing")
assert(text:find("├─ ✓ Edited", 1, true), "tool timeline did not connect its first action")
assert(text:find("╰─ ✓ Read", 1, true), "tool timeline did not terminate its last action")
assert(text:find("Edited  lua/example.lua", 1, true), "edit title is missing")
assert(text:find("+1 -1", 1, true), "edit title is missing its diff statistics")
assert(text:find("- local old = true", 1, true), "deleted diff line is missing")
assert(text:find("+ local new = true", 1, true), "added diff line is missing")
assert(text:find("Ran  printf hello", 1, true), "bash title is missing")
assert(text:find("line 1", 1, true) and text:find("line 12", 1, true), "bash preview must keep its head and tail")
assert(not text:find("line 6", 1, true), "bash preview did not collapse its middle")
assert(text:find("lines hidden · Ctrl-O expand", 1, true), "bash collapse hint is missing")
assert(text:find("Read  README.md:1", 1, true), "read title is missing")
assert(text:find("2 lines · Ctrl-O expand", 1, true), "read summary is missing")
assert(not text:find("raw file content", 1, true), "collapsed read leaked file contents")
assert(#tool_ranges == 3 and tool_ranges[1].first <= tool_ranges[1].last, "tool row ranges are missing")

local soft_break_lines = renderer.render({
  {
    type = "assistant",
    message = {
      role = "assistant",
      content = {
        {
          type = "text",
          text = "我会沿 client ->\nruntime -> `render/UI` -> extensions\n逐层检查。\n\n显式硬换行  \n必须另起一行",
        },
      },
    },
  },
}, { width = 80 })
local soft_break_text = table.concat(soft_break_lines, "\n")
assert(
  soft_break_text:find("我会沿 client -> runtime -> render/UI -> extensions 逐层检查。", 1, true),
  "Markdown soft breaks must remain in one logical buffer line"
)
assert(
  soft_break_text:find("显式硬换行\n   必须另起一行", 1, true),
  "Markdown hard breaks must remain separate buffer lines"
)

local multiline_error_lines = renderer.render({
  {
    type = "assistant",
    message = {
      content = {},
      stopReason = "error",
      errorMessage = "first line\r\nsecond line",
    },
  },
}, { width = 80 })
local multiline_error_text = table.concat(multiline_error_lines, "\n")
assert(
  multiline_error_text:find(" Error: first line\n        second line", 1, true),
  "multiline assistant error was not rendered as separate buffer rows"
)
for index, line in ipairs(multiline_error_lines) do
  assert(
    not line:find("[\r\n]"),
    ("rendered error row %d contains an embedded newline: %s"):format(index, vim.inspect(line))
  )
end

local highlights = {}
for _, mark in ipairs(marks) do
  if mark.highlight then
    highlights[mark.highlight] = true
  end
end
assert(highlights.PiUserMessageText, "user semantic highlight is missing")
assert(highlights.PiMarkdownHeading, "heading semantic highlight is missing")
assert(highlights.PiMarkdownCode, "code semantic highlight is missing")
if lua_parser_available then
  assert(highlights["@keyword.lua"], "Lua keyword syntax highlight is missing")
  assert(highlights["@boolean.lua"], "Lua boolean syntax highlight is missing")
end
assert(highlights.PiMarkdownStrong, "strong inline highlight is missing")
assert(highlights.PiMarkdownInlineCode, "inline code highlight is missing")
assert(highlights.PiMarkdownLink, "link highlight is missing")
assert(highlights.PiMarkdownListMarker, "list marker highlight is missing")
assert(highlights.PiDiffDelete and highlights.PiDiffAdd, "diff semantic highlights are missing")
assert(highlights.PiDiffDeleteLine and highlights.PiDiffAddLine, "diff line surfaces are missing")
assert(highlights.PiToolVerb and highlights.PiToolSuccess, "tool header highlights are missing")
assert(highlights.PiToolGutter and highlights.PiToolOutput, "tool output highlights are missing")
assert(highlights.PiToolGroupLabel and highlights.PiToolSubject, "tool hierarchy highlights are missing")
assert(highlights.PiToolSurface, "tool output surface is missing")
assert(highlights.PiToolOmitted, "collapsed output highlight is missing")

local compact_lines, compact_marks, compact_tool_ranges, compact_process_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = false,
  hide_thinking = true,
  tools_expanded = false,
  width = 80,
})
local compact_text = table.concat(compact_lines, "\n")
local compact_answer =
  assert(compact_text:find(" Result", 1, true), "completed process lost the public assistant response")
local compact_summary = assert(
  compact_text:find("▸ Thought for 18.1s, ran 1 command, read 1 file, edited 1 file", 1, true),
  "completed process summary is missing its duration and action counts"
)
assert(compact_answer < compact_summary, "process summary must follow the public assistant response")
assert(compact_text:find("· Ctrl-O", compact_summary, true), "process summary is missing its toggle hint")
assert(not compact_text:find("reasoning", 1, true), "completed process leaked thinking details")
assert(not compact_text:find("Actions", 1, true), "completed process leaked its tool timeline")
assert(not compact_text:find("printf hello", 1, true), "completed process leaked a command")
assert(#compact_tool_ranges == 0, "hidden tools retained clickable ranges")
assert(#compact_process_ranges == 1, "collapsed process summary is not clickable")
local compact_highlights = {}
for _, mark in ipairs(compact_marks) do
  if mark.highlight then
    compact_highlights[mark.highlight] = true
  end
end
assert(compact_highlights.PiProcessSummary, "process summary semantic highlight is missing")
assert(compact_highlights.PiProcessToggle, "process disclosure marker highlight is missing")
assert(compact_highlights.PiHeaderHint, "process toggle hint semantic highlight is missing")

local staged_items = {
  { type = "user", text = "Inspect the project" },
  {
    type = "assistant",
    duration_ms = 1000,
    message = {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "first private step" },
        { type = "text", text = "First update" },
      },
    },
  },
  {
    type = "tool",
    id = "staged-read",
    name = "read",
    state = "done",
    duration_ms = 1000,
    args = { path = "README.md" },
    result = { content = { { type = "text", text = "contents" } } },
  },
  {
    type = "assistant",
    duration_ms = 3000,
    message = {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "final private step" },
        { type = "text", text = "Final answer" },
      },
      stopReason = "stop",
    },
  },
}
local staged_lines, _, staged_tool_ranges, staged_process_ranges = renderer.render(staged_items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = false,
  width = 80,
})
local staged_text = table.concat(staged_lines, "\n")
local first_update = assert(staged_text:find("First update", 1, true), "first staged update is missing")
local first_summary = assert(
  staged_text:find("▸ Thought for 2s, read 1 file", first_update, true),
  "first stage summary lost its duration or file count"
)
local final_answer = assert(staged_text:find("Final answer", first_summary, true), "final staged answer is missing")
local final_summary =
  assert(staged_text:find("▸ Thought for 3s", final_answer, true), "final stage summary lost its duration")
assert(
  first_update < first_summary and first_summary < final_answer and final_answer < final_summary,
  "staged process order is wrong"
)
assert(#staged_tool_ranges == 0, "collapsed staged tools retained clickable ranges")
assert(#staged_process_ranges == 2, "each completed stage must expose a process toggle")

local active_staged_lines, _, active_staged_tool_ranges, active_staged_process_ranges = renderer.render(staged_items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  width = 80,
})
local active_staged_text = table.concat(active_staged_lines, "\n")
assert(active_staged_text:find("First update", 1, true), "completed active-turn stage lost its public update")
assert(
  active_staged_text:find("▸ Thought for 2s, read 1 file", 1, true),
  "completed active-turn stage did not collapse"
)
assert(not active_staged_text:find("first private step", 1, true), "completed active-turn stage leaked private details")
assert(not active_staged_text:find("final private step", 1, true), "current active stage leaked live thinking")
assert(active_staged_text:find("Final answer", 1, true), "current active stage lost its public answer")
assert(not active_staged_text:find("▸ Thought for 3s", 1, true), "current active stage collapsed before settlement")
assert(#active_staged_tool_ranges == 0, "hidden completed-stage tool retained a clickable range")
assert(#active_staged_process_ranges == 1, "only completed active-turn stages should expose process toggles")

local narrow_compact_lines = renderer.render(items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = false,
  width = 42,
})
local narrow_process_summary = nil
for _, line in ipairs(narrow_compact_lines) do
  if line:find("▸", 1, true) then
    narrow_process_summary = line
  end
end
assert(narrow_process_summary, "narrow process summary is missing")
assert(vim.api.nvim_strwidth(narrow_process_summary) <= 42, "narrow process summary overflowed the transcript")

local active_lines, _, active_tool_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  hide_thinking = true,
  tools_expanded = false,
  width = 80,
})
local active_text = table.concat(active_lines, "\n")
assert(not active_text:find("reasoning", 1, true), "active process leaked live thinking")
assert(not active_text:find("Thinking...", 1, true), "active process duplicated thinking status in the transcript")
assert(active_text:find("Actions", 1, true), "active process must show live tools")
assert(not active_text:find("▸ Thought", 1, true), "active process was summarized before completion")
assert(#active_tool_ranges == 3, "active tool rows are not interactive")

local thinking_only_lines = renderer.render({
  { type = "user", text = "Wait for the result" },
  {
    type = "assistant",
    message = {
      role = "assistant",
      content = { { type = "thinking", thinking = "private live reasoning" } },
    },
  },
}, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  width = 80,
})
assert(#thinking_only_lines == 1, "hidden live thinking left a blank transcript row")

local active_detailed_lines = renderer.render(items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = true,
  width = 80,
})
assert(
  table.concat(active_detailed_lines, "\n"):find("reasoning", 1, true),
  "expanded active process did not reveal thinking"
)

local detailed_lines, _, detailed_tool_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = true,
  width = 80,
})
local detailed_text = table.concat(detailed_lines, "\n")
assert(detailed_text:find("reasoning", 1, true), "completed process details did not expand")
assert(detailed_text:find("raw file content", 1, true), "expanded process did not reveal tool output")
assert(#detailed_tool_ranges == 3, "expanded process tool ranges are missing")

local fallback_lines, fallback_marks = renderer.render({
  {
    type = "assistant",
    message = {
      role = "assistant",
      content = {
        { type = "text", text = "```language-without-a-parser\nplain fallback\n```" },
      },
    },
  },
}, { width = 80 })
assert(table.concat(fallback_lines, "\n"):find("plain fallback", 1, true), "unknown code language did not render")
local fallback_code_highlight = false
for _, mark in ipairs(fallback_marks) do
  fallback_code_highlight = fallback_code_highlight or mark.highlight == "PiMarkdownCode"
end
assert(fallback_code_highlight, "unknown code language lost its fallback highlight")

local expanded_code_lines, expanded_code_marks, expanded_code_ranges = renderer.render({
  {
    type = "tool",
    id = "read-lua",
    name = "read",
    state = "done",
    expanded = true,
    args = { path = "lua/example.lua", offset = 1 },
    result = { content = { { type = "text", text = "local value = true\nreturn value" } } },
  },
}, { width = 80 })
assert(table.concat(expanded_code_lines, "\n"):find("local value = true", 1, true), "expanded Lua read is missing")
local expanded_code_range = assert(expanded_code_ranges[1], "expanded Lua read range is missing")
local expanded_code_highlights = {}
for _, mark in ipairs(expanded_code_marks) do
  local row = mark.row + 1
  if row >= expanded_code_range.first and row <= expanded_code_range.last and mark.highlight then
    expanded_code_highlights[mark.highlight] = true
  end
end
if lua_parser_available then
  assert(expanded_code_highlights["@keyword.lua"], "expanded Lua read is missing keyword highlighting")
  assert(expanded_code_highlights["@boolean.lua"], "expanded Lua read is missing boolean highlighting")
end

local narrow_tool_lines = renderer.render({ items[3] }, {
  hide_thinking = true,
  tools_expanded = false,
  width = 42,
})
local narrow_tool_text = table.concat(narrow_tool_lines, "\n")
assert(narrow_tool_text:find("Edited  example.lua", 1, true), "narrow edit header did not collapse its path")
assert(narrow_tool_text:find("+1 -1", 1, true), "narrow edit header lost its diff statistics")
assert(not narrow_tool_text:find("12.0s", 1, true), "narrow edit header should drop secondary duration metadata")
for _, line in ipairs(narrow_tool_lines) do
  assert(vim.api.nvim_strwidth(line) <= 42, "narrow tool timeline overflowed the window")
end

local branded_lines = renderer.render({ items[1] }, {
  width = 80,
  welcome = {
    model = "gpt-5.6-sol",
    thinking = "high",
    root = "/tmp/pi.nvim",
    permission = "confirm",
  },
})
local branded_text = table.concat(branded_lines, "\n")
assert(
  branded_text:find("████████████", 1, true),
  "welcome logo did not persist in the transcript"
)
assert(branded_text:find("Review this", 1, true), "conversation did not render after the welcome card")
assert(
  branded_text:find("████████████", 1, true) < branded_text:find("Review this", 1, true),
  "welcome card must precede the conversation"
)

items[#items].expanded = true
lines = renderer.render(items, { hide_thinking = true, tools_expanded = false, width = 80 })
text = table.concat(lines, "\n")
assert(text:find("raw file content", 1, true), "expanded read output is missing")

print("render_spec: ok")
