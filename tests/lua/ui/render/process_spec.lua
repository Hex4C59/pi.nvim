local renderer = require("pi.ui.render")

local function result(text)
  return { content = text and { { type = "text", text = text } } or {} }
end

local function rendered_text(lines)
  return table.concat(lines, "\n")
end

local function highlight_set(marks)
  local groups = {}
  for _, mark in ipairs(marks) do
    if mark.highlight then
      groups[mark.highlight] = true
    end
  end
  return groups
end

local function assert_process_ranges(lines, ranges, expected)
  assert(#ranges == expected, "process range count changed")
  for _, range in ipairs(ranges) do
    assert(range.first <= range.last, "process range is reversed")
    assert(range.first >= 1 and range.last <= #lines, "process range falls outside rendered output")
  end
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
      content = {
        { type = "thinking", thinking = "reasoning" },
        { type = "text", text = "Result" },
      },
    },
  },
  {
    type = "tool",
    id = "edit-1",
    name = "edit",
    state = "done",
    duration_ms = 12000,
    args = { path = "lua/example.lua", oldText = "old", newText = "new" },
    result = result("Updated lua/example.lua"),
  },
  {
    type = "tool",
    id = "bash-1",
    name = "bash",
    state = "done",
    args = { command = "printf hello" },
    result = result(table.concat(bash_lines, "\n")),
  },
  {
    type = "tool",
    id = "read-1",
    name = "read",
    state = "done",
    args = { path = "README.md", offset = 1 },
    result = result("<p>raw file content</p>\nsecond line"),
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
local compact_text = rendered_text(compact_lines)
local compact_answer = assert(compact_text:find(" Result", 1, true), "completed process lost its public response")
local compact_summary = assert(
  compact_text:find("▸ Thought for 18.1s, ran 1 command, read 1 file, edited 1 file", 1, true),
  "completed process summary lost its duration or action counts"
)
assert(compact_answer < compact_summary, "process summary must follow the public response")
assert(compact_text:find("· Ctrl-O", compact_summary, true), "process summary toggle hint is missing")
assert(not compact_text:find("reasoning", 1, true), "completed process leaked private thinking")
assert(not compact_text:find("Actions", 1, true), "completed process leaked its tool timeline")
assert(not compact_text:find("printf hello", 1, true), "completed process leaked tool details")
assert(#compact_tool_ranges == 0, "hidden process tools retained clickable ranges")
assert_process_ranges(compact_lines, compact_process_ranges, 1)
local compact_highlights = highlight_set(compact_marks)
assert(compact_highlights.PiProcessSummary, "process summary semantic highlight is missing")
assert(compact_highlights.PiProcessToggle, "process disclosure marker highlight is missing")
assert(compact_highlights.PiHeaderHint, "process toggle hint highlight is missing")

local action_items = {
  { type = "user", text = "Count work" },
  {
    type = "assistant",
    duration_ms = 1000,
    message = { content = { { type = "thinking", thinking = "counting" }, { type = "text", text = "Done" } } },
  },
}
for _, tool in ipairs({
  { name = "bash", args = { command = "cmd" } },
  { name = "read", args = { path = "a" } },
  { name = "ls", args = { path = "." } },
  { name = "grep", args = { pattern = "a" } },
  { name = "find", args = { pattern = "*.lua" } },
  { name = "edit", args = { path = "a", oldText = "a", newText = "b" } },
  { name = "write", args = { path = "b", content = "b" } },
  { name = "custom", args = {}, error = true },
}) do
  table.insert(action_items, {
    type = "tool",
    name = tool.name,
    state = "done",
    error = tool.error,
    duration_ms = 1000,
    args = tool.args,
    result = result(tool.error and "failed" or "ok"),
  })
end
local action_lines, _, action_tool_ranges, action_process_ranges = renderer.render(action_items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = false,
  width = 200,
})
local action_text = rendered_text(action_lines)
assert(
  action_text:find(
    "Thought for 9s, ran 1 command, read 1 file, listed 1 directory, searched 2 queries, edited 2 files, used 1 tool, 1 failure",
    1,
    true
  ),
  "completed process did not count every supported action category exactly once"
)
assert(#action_tool_ranges == 0, "comprehensive compact summary exposed tool ranges")
assert_process_ranges(action_lines, action_process_ranges, 1)

local staged_items = {
  { type = "user", text = "Inspect the project" },
  {
    type = "assistant",
    duration_ms = 1000,
    message = {
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
    result = result("contents"),
  },
  {
    type = "assistant",
    duration_ms = 3000,
    message = {
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
local staged_text = rendered_text(staged_lines)
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
  "staged process order changed"
)
assert(#staged_tool_ranges == 0, "collapsed staged tools retained clickable ranges")
assert_process_ranges(staged_lines, staged_process_ranges, 2)

local turn_items = {
  { type = "user", text = "First turn" },
  {
    type = "assistant",
    message = { content = { { type = "thinking", thinking = "first" }, { type = "text", text = "First reply" } } },
  },
  { type = "tool", name = "bash", state = "done", args = { command = "first command" }, result = result("one") },
  { type = "user", text = "Second turn" },
  {
    type = "assistant",
    message = { content = { { type = "thinking", thinking = "second" }, { type = "text", text = "Second reply" } } },
  },
  { type = "tool", name = "read", state = "done", args = { path = "second" }, result = result("two") },
}
local turn_lines, _, turn_tool_ranges, turn_process_ranges = renderer.render(turn_items, {
  collapse_processes = true,
  process_active = false,
  width = 80,
})
local turn_text = rendered_text(turn_lines)
local first_turn_summary = assert(turn_text:find("ran 1 command", 1, true), "first user turn summary is missing")
local second_turn = assert(turn_text:find("Second turn", first_turn_summary, true), "second user turn is missing")
local second_turn_summary =
  assert(turn_text:find("read 1 file", second_turn, true), "second user turn summary is missing")
assert(first_turn_summary < second_turn and second_turn < second_turn_summary, "unrelated user turns were merged")
assert(#turn_tool_ranges == 0, "settled user turns exposed hidden tool ranges")
assert_process_ranges(turn_lines, turn_process_ranges, 2)

local active_staged_lines, _, active_staged_tool_ranges, active_staged_process_ranges = renderer.render(staged_items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  width = 80,
})
local active_staged_text = rendered_text(active_staged_lines)
assert(active_staged_text:find("First update", 1, true), "completed active-turn stage lost its public update")
assert(
  active_staged_text:find("▸ Thought for 2s, read 1 file", 1, true),
  "completed active-turn stage did not collapse"
)
assert(not active_staged_text:find("first private step", 1, true), "completed active-turn stage leaked private details")
assert(not active_staged_text:find("final private step", 1, true), "current active stage leaked live thinking")
assert(active_staged_text:find("Final answer", 1, true), "current active stage lost its public partial answer")
assert(not active_staged_text:find("▸ Thought for 3s", 1, true), "active stage collapsed before settlement")
assert(#active_staged_tool_ranges == 0, "hidden completed-stage tool retained a clickable range")
assert_process_ranges(active_staged_lines, active_staged_process_ranges, 1)

local active_lines, _, active_tool_ranges, active_process_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  hide_thinking = false,
  tools_expanded = false,
  width = 80,
})
local active_text = rendered_text(active_lines)
assert(not active_text:find("reasoning", 1, true), "active process leaked live thinking")
assert(not active_text:find("Thinking...", 1, true), "active process duplicated thinking metadata")
assert(active_text:find("Actions", 1, true), "active process did not show completed tools")
assert(active_text:find("Result", 1, true), "active process lost public partial output")
assert(not active_text:find("▸ Thought", 1, true), "active process summarized before settlement")
assert(#active_tool_ranges == 3, "active process tool rows are not interactive")
assert_process_ranges(active_lines, active_process_ranges, 0)
assert(compact_text:find("▸ Thought", 1, true), "settled transition did not produce a compact summary")

local thinking_only_lines, _, thinking_tool_ranges, thinking_process_ranges = renderer.render({
  { type = "user", text = "Wait for the result" },
  { type = "assistant", message = { content = { { type = "thinking", thinking = "private live reasoning" } } } },
}, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  width = 80,
})
assert(#thinking_only_lines == 1, "hidden thinking-only activity left a blank transcript row")
assert(#thinking_tool_ranges == 0 and #thinking_process_ranges == 0, "thinking-only activity exposed stale ranges")

local active_expanded_lines, _, active_expanded_tool_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  tools_expanded = true,
  width = 80,
})
local active_expanded_text = rendered_text(active_expanded_lines)
assert(active_expanded_text:find("raw file content", 1, true), "global tool expansion did not reveal active output")
assert(#active_expanded_tool_ranges == 3, "global tool expansion lost active tool ranges")

local per_tool_items = vim.deepcopy(items)
per_tool_items[#per_tool_items].expanded = true
local per_tool_lines, _, per_tool_ranges = renderer.render(per_tool_items, {
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  tools_expanded = false,
  width = 80,
})
assert(
  rendered_text(per_tool_lines):find("raw file content", 1, true),
  "per-tool expansion did not reveal active output"
)
assert(#per_tool_ranges == 3, "per-tool expansion lost active tool ranges")

local detailed_lines, _, detailed_tool_ranges, detailed_process_ranges = renderer.render(items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = true,
  hide_thinking = true,
  tools_expanded = false,
  width = 80,
})
local detailed_text = rendered_text(detailed_lines)
local reasoning_at = assert(detailed_text:find("reasoning", 1, true), "expanded process did not reveal thinking")
local edit_at = assert(detailed_text:find("Edited", reasoning_at, true), "expanded process lost edit details")
local bash_at = assert(detailed_text:find("Ran", edit_at, true), "expanded process lost Bash details")
local read_at = assert(detailed_text:find("Read", bash_at, true), "expanded process lost read details")
local output_at = assert(detailed_text:find("raw file content", read_at, true), "expanded process lost tool output")
assert(
  reasoning_at < edit_at and edit_at < bash_at and bash_at < read_at and read_at < output_at,
  "expanded process reordered chronological details"
)
assert(#detailed_tool_ranges == 3, "expanded process tool ranges are missing")
assert_process_ranges(detailed_lines, detailed_process_ranges, 0)

local narrow_lines = renderer.render(items, {
  collapse_processes = true,
  process_active = false,
  process_expanded = false,
  width = 42,
})
local narrow_summary
for _, line in ipairs(narrow_lines) do
  if line:find("▸", 1, true) then
    narrow_summary = line
  end
end
assert(narrow_summary, "narrow process summary is missing")
assert(vim.api.nvim_strwidth(narrow_summary) <= 42, "narrow process summary overflowed the transcript")
assert(
  narrow_summary:find("▸ Thought for 18.1s", 1, true),
  "narrow summary replaced its primary duration with misleading prose"
)
assert(narrow_summary:find("...", 1, true), "narrow summary did not shorten lower-priority detail deterministically")
assert(not narrow_summary:find("Ctrl-O", 1, true), "truncated narrow summary retained a partial toggle hint")

print("render_process_spec: ok")
