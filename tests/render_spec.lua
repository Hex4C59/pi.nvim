local renderer = require("pi.ui.render")

local welcome_lines, welcome_marks = renderer.render_welcome({
  width = 80,
  model = "gpt-5.6-sol",
  thinking = "high",
  root = "/tmp/pi.nvim",
  permission = "confirm",
})
local welcome_text = table.concat(welcome_lines, "\n")
assert(welcome_lines[1]:find("╭", 1, true), "welcome card must start on the first transcript row")
assert(welcome_lines[1]:find("PI · coding agent", 1, true), "welcome title must be integrated into the border")
assert(welcome_lines[1]:find("┬", 1, true), "wide welcome must expose the two-column structure")
assert(welcome_text:find("████████████", 1, true), "Pi welcome logo is missing")
assert(welcome_text:find("coding agent", 1, true), "Pi introduction is missing")
assert(welcome_text:find("Session", 1, true), "welcome session section is missing")
assert(welcome_text:find("Workspace", 1, true), "welcome workspace section is missing")
assert(welcome_text:find("gpt-5.6-sol · high", 1, true), "welcome model state is missing")
assert(welcome_text:find("/tmp/pi.nvim", 1, true), "welcome project is missing")
assert(welcome_text:find("confirm changes", 1, true), "welcome permission mode is missing")
assert(not welcome_text:find("Enter send", 1, true), "welcome send hint should be removed")
assert(not welcome_text:find("Ctrl-J", 1, true), "welcome newline hint should be removed")
assert(not welcome_text:find("/hotkeys", 1, true), "welcome keybinding hint should be removed")
assert(not welcome_text:find("/commands", 1, true), "welcome should not advertise the redundant command browser")
for _, line in ipairs(welcome_lines) do
  assert(vim.fn.strdisplaywidth(line) == 80, "welcome card must fill the transcript width")
end

local welcome_highlights = {}
for _, mark in ipairs(welcome_marks) do
  if mark.highlight then
    welcome_highlights[mark.highlight] = true
  end
end
for index = 1, 4 do
  assert(welcome_highlights["PiWelcomeLogo" .. index], "welcome logo color segment is missing")
end
assert(welcome_highlights.PiWelcomeTitle, "welcome brand highlight is missing")
assert(welcome_highlights.PiWelcomeAgent, "welcome agent highlight is missing")
assert(welcome_highlights.PiWelcomeNeovim, "welcome Neovim highlight is missing")
assert(welcome_highlights.PiWelcomeSection, "welcome section highlight is missing")
assert(welcome_highlights.PiWelcomeModelValue, "welcome model highlight is missing")
assert(welcome_highlights.PiWelcomeThinkingValue, "welcome thinking highlight is missing")
assert(welcome_highlights.PiWelcomeProjectValue, "welcome project highlight is missing")
assert(welcome_highlights.PiWelcomePermissionValue, "welcome permission highlight is missing")
assert(not welcome_highlights.PiWelcomeKey, "removed welcome shortcut highlight is still present")

local narrow_welcome = renderer.render_welcome({
  width = 42,
  model = "a-model-with-a-deliberately-long-name",
  thinking = "high",
  root = "/tmp/a/deliberately/long/project/path/pi.nvim",
  permission = "full",
})
assert(not narrow_welcome[1]:find("┬", 1, true), "narrow welcome must fall back to one column")
for _, line in ipairs(narrow_welcome) do
  assert(vim.fn.strdisplaywidth(line) == 42, "narrow welcome card must fill without overflowing the window")
end

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
assert(text:find(" ▎ YOU\n   Review this", 1, true), "user text must align with the YOU label")
assert(text:find("◆ PI  ·  Thought 6.1s", 1, true), "thinking duration is missing from the assistant header")
assert(not text:find("+ Thought", 1, true), "thinking duration still occupies a separate row")
assert(not text:find("reasoning", 1, true), "thinking should be collapsed")
assert(text:find("◆ PI", 1, true) < text:find(" Result", 1, true), "assistant header must precede the final response")
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

local highlights = {}
for _, mark in ipairs(marks) do
  if mark.highlight then
    highlights[mark.highlight] = true
  end
end
assert(highlights.PiUserMessageText, "user semantic highlight is missing")
assert(highlights.PiMarkdownHeading, "heading semantic highlight is missing")
assert(highlights.PiMarkdownCode, "code semantic highlight is missing")
assert(highlights["@keyword.lua"], "Lua keyword syntax highlight is missing")
assert(highlights["@boolean.lua"], "Lua boolean syntax highlight is missing")
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
assert(
  compact_text:find("▸ Thought for 18.1s, ran 1 command, read 1 file, edited 1 file", 1, true),
  "completed process summary is missing its duration and action counts"
)
assert(compact_text:find(" Result", 1, true), "completed process lost the public assistant response")
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
assert(active_text:find("reasoning", 1, true), "active process must show live thinking")
assert(active_text:find("Actions", 1, true), "active process must show live tools")
assert(not active_text:find("▸ Thought", 1, true), "active process was summarized before completion")
assert(#active_tool_ranges == 3, "active tool rows are not interactive")

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
assert(expanded_code_highlights["@keyword.lua"], "expanded Lua read is missing keyword highlighting")
assert(expanded_code_highlights["@boolean.lua"], "expanded Lua read is missing boolean highlighting")

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
assert(branded_text:find("████████████", 1, true), "welcome logo did not persist in the transcript")
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
