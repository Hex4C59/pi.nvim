local renderer = require("pi.ui.render")

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
          text = "Result",
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

print("render_spec: ok")
