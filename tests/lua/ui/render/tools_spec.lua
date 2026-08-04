local renderer = require("pi.ui.render")

local function result(text, details)
  return {
    content = text and { { type = "text", text = text } } or {},
    details = details,
  }
end

local function render_tools(items, opts)
  return renderer.render(
    items,
    vim.tbl_extend("force", {
      width = 80,
      tools_expanded = false,
    }, opts or {})
  )
end

local function rendered_text(lines)
  return table.concat(lines, "\n")
end

local function has_row(lines, expected)
  for _, line in ipairs(lines) do
    if vim.trim(line) == expected then
      return true
    end
  end
  return false
end

local function highlight_set(marks, range)
  local groups = {}
  for _, mark in ipairs(marks) do
    local row = mark.row + 1
    if (not range or (row >= range.first and row <= range.last)) and mark.highlight then
      groups[mark.highlight] = true
    end
  end
  return groups
end

local function assert_ranges(lines, ranges, items)
  assert(#ranges == #items, "visible tools must each own one row range")
  for index, range in ipairs(ranges) do
    assert(range.item == items[index], "tool range lost its structured item identity")
    assert(range.first <= range.last, "tool range columns are reversed")
    assert(range.first >= 1 and range.last <= #lines, "tool range falls outside rendered output")
  end
end

local function assert_width(lines, width)
  for _, line in ipairs(lines) do
    assert(vim.api.nvim_strwidth(line) <= width, "tool row exceeded the requested display width")
    vim.str_utfindex(line)
  end
end

local bash_lines = {}
for index = 1, 12 do
  table.insert(bash_lines, "line " .. index)
end
local core_tools = {
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
local core_lines, core_marks, core_ranges = render_tools(core_tools)
local core_text = rendered_text(core_lines)
assert(core_text:find("Actions", 1, true), "tool group label is missing")
assert(core_text:find("├─ ✓ Edited", 1, true), "tool timeline did not connect its first action")
assert(core_text:find("╰─ ✓ Read", 1, true), "tool timeline did not terminate its last action")
assert(core_text:find("Edited  lua/example.lua", 1, true), "edit title is missing")
assert(core_text:find("+1 -1", 1, true), "edit title is missing its diff statistics")
assert(core_text:find("-   │ local old = true", 1, true), "deleted diff line is missing")
assert(core_text:find("+   │ local new = true", 1, true), "added diff line is missing")
assert(core_text:find("Ran  printf hello", 1, true), "Bash title is missing")
assert(core_text:find("line 1", 1, true) and core_text:find("line 12", 1, true), "Bash preview lost its edges")
assert(not core_text:find("line 6", 1, true), "collapsed Bash preview retained its middle")
assert(core_text:find("lines hidden · Ctrl-O expand", 1, true), "Bash collapse hint is missing")
assert(core_text:find("Read  README.md:1", 1, true), "read title is missing")
assert(core_text:find("2 lines · Ctrl-O expand", 1, true), "collapsed read summary is missing")
assert(not core_text:find("raw file content", 1, true), "collapsed read leaked file contents")
assert_ranges(core_lines, core_ranges, core_tools)

local core_highlights = highlight_set(core_marks)
for _, group in ipairs({
  "PiDiffDelete",
  "PiDiffAdd",
  "PiDiffDeleteLine",
  "PiDiffAddLine",
  "PiToolVerb",
  "PiToolSuccess",
  "PiToolGutter",
  "PiToolOutput",
  "PiToolGroupLabel",
  "PiToolSubject",
  "PiToolCommand",
  "PiToolSurface",
  "PiToolOmitted",
}) do
  assert(core_highlights[group], "tool semantic highlight is missing: " .. group)
end

local known = {
  bash = { args = { command = "printf matrix" }, subject = "printf matrix", pending = "Running", done = "Ran" },
  read = {
    args = { path = "src/main.lua", offset = 7 },
    subject = "src/main.lua:7",
    pending = "Reading",
    done = "Read",
  },
  write = {
    args = { path = "src/new.lua", content = "return true" },
    subject = "src/new.lua",
    pending = "Writing",
    done = "Wrote",
  },
  edit = {
    args = { path = "src/edit.lua", oldText = "old", newText = "new" },
    subject = "src/edit.lua",
    pending = "Editing",
    done = "Edited",
  },
  grep = {
    args = { pattern = "needle", path = "src" },
    subject = "needle in src",
    pending = "Searching",
    done = "Searched",
  },
  find = { args = { glob = "*.lua", path = "src" }, subject = "*.lua in src", pending = "Searching", done = "Searched" },
  ls = { args = { path = "src" }, subject = "src", pending = "Listing", done = "Listed" },
}
for name, fixture in pairs(known) do
  for _, state in ipairs({ "pending", "done", "failed" }) do
    local item = {
      type = "tool",
      name = name,
      state = state == "pending" and "pending" or "done",
      error = state == "failed",
      duration_ms = 1200,
      args = fixture.args,
      result = state == "failed" and result("failure tail") or result("ok"),
    }
    local lines, marks, ranges = render_tools({ item })
    local text = rendered_text(lines)
    local expected_verb = state == "failed" and "Failed" or fixture[state]
    assert(text:find(expected_verb, 1, true), name .. " tool verb changed for " .. state)
    assert(text:find(fixture.subject, 1, true), name .. " tool subject changed for " .. state)
    assert(
      text:find(state == "pending" and "◌" or state == "failed" and "×" or "✓", 1, true),
      "tool status glyph changed"
    )
    assert(text:find("1.2s", 1, true), "wide tool header lost duration metadata")
    local groups = highlight_set(marks)
    assert(groups.PiToolVerb, "known tool verb highlight is missing")
    assert(
      groups[state == "pending" and "PiToolRunning" or state == "failed" and "PiToolFailed" or "PiToolSuccess"],
      "tool state highlight is missing"
    )
    assert_ranges(lines, ranges, { item })
  end
end

local circular = {}
circular.self = circular
local unknown_tools = {
  { type = "tool", name = "custom-empty", state = "done", args = {}, result = result(nil) },
  { type = "tool", name = "custom-small", state = "done", args = { key = "value" }, result = result(nil) },
  {
    type = "tool",
    name = "custom-deep",
    state = "done",
    args = { nested = { one = { two = { three = string.rep("value", 50) } } }, broad = { 1, 2, 3, 4, 5 } },
    result = result(nil),
  },
  { type = "tool", name = "custom-circular", state = "done", args = circular, result = result(nil) },
}
local unknown_lines, unknown_marks, unknown_ranges = render_tools(unknown_tools, { width = 72 })
local unknown_text = rendered_text(unknown_lines)
assert(unknown_text:find("Used  custom-empty", 1, true), "unknown tool with empty args lost its name")
assert(unknown_text:find("custom-small  {\"key\":\"value\"}", 1, true), "unknown tool args were not serialized")
assert(unknown_text:find("custom-deep", 1, true), "bounded structured custom args did not render")
assert(unknown_text:find("...", 1, true), "long encoded custom-tool subject was not truncated")
assert(unknown_text:find("Used  custom-circular", 1, true), "JSON encoding failure did not fall back to the tool name")
assert_ranges(unknown_lines, unknown_ranges, unknown_tools)
assert_width(unknown_lines, 72)
assert(highlight_set(unknown_marks).PiToolCommand, "custom tool command highlight is missing")

local diff_tools = {
  {
    type = "tool",
    name = "edit",
    state = "done",
    args = { path = "compat.lua", old_string = "old compatibility", new_string = "new compatibility" },
    result = result(nil),
  },
  {
    type = "tool",
    name = "edit",
    state = "done",
    args = {
      path = "multiple.lua",
      edits = {
        { oldText = "old one\r\n旧二", newText = "new one" },
        { oldText = "", newText = "新增一\r\nnew two" },
      },
    },
    result = result(nil),
  },
  {
    type = "tool",
    name = "write",
    state = "done",
    args = { path = "written.lua", content = "第一行\r\nsecond line" },
    result = result(nil),
  },
  {
    type = "tool",
    name = "edit",
    state = "done",
    args = { path = "empty.lua", oldText = "", newText = "" },
    result = result(nil),
  },
}
local diff_lines, diff_marks, diff_ranges = render_tools(diff_tools, { tools_expanded = true })
local diff_text = rendered_text(diff_lines)
assert(diff_text:find("+1 -1", 1, true), "compatibility edit counts changed")
assert(diff_text:find("+3 -2", 1, true), "multiple edit counts changed")
assert(diff_text:find("+2", 1, true), "write addition count changed")
assert(
  diff_text:find("-   │ 旧二", 1, true) and diff_text:find("+   │ 新增一", 1, true),
  "UTF-8 CRLF diff rows changed"
)
assert(not diff_text:find("empty.lua  +", 1, true), "empty edit rendered false diff counts")
local diff_highlights = highlight_set(diff_marks)
assert(diff_highlights.PiDiffDeleteLine and diff_highlights.PiDiffAddLine, "diff line surfaces are missing")
assert_ranges(diff_lines, diff_ranges, diff_tools)

local large_edits = {}
for index = 1, 12 do
  table.insert(large_edits, { oldText = "old " .. index, newText = "new " .. index })
end
local large_edit = {
  type = "tool",
  name = "edit",
  state = "done",
  args = { path = "large.lua", edits = large_edits },
  result = result(nil),
}
local collapsed_diff_lines, _, collapsed_diff_ranges = render_tools({ large_edit })
local expanded_diff_lines, _, expanded_diff_ranges = render_tools({ large_edit }, { tools_expanded = true })
assert(
  rendered_text(collapsed_diff_lines):find("diff lines hidden", 1, true),
  "collapsed edit did not summarize diff rows"
)
assert(
  rendered_text(expanded_diff_lines):find("-   │ old 6", 1, true),
  "expanded edit did not reveal middle diff rows"
)
assert(
  expanded_diff_ranges[1].last - expanded_diff_ranges[1].first
    > collapsed_diff_ranges[1].last - collapsed_diff_ranges[1].first,
  "expanded edit range did not grow with visible details"
)

local write_content = {}
for index = 1, 10 do
  table.insert(write_content, "write " .. index)
end
local large_write = {
  type = "tool",
  name = "write",
  state = "done",
  args = { path = "large-write.lua", content = table.concat(write_content, "\n") },
  result = result(nil),
}
local collapsed_write_lines, _, collapsed_write_ranges = render_tools({ large_write })
local expanded_write_lines, _, expanded_write_ranges = render_tools({ large_write }, { tools_expanded = true })
assert(
  rendered_text(collapsed_write_lines):find("lines hidden", 1, true),
  "collapsed write did not summarize additions"
)
assert(has_row(expanded_write_lines, "+  5 │ write 5"), "expanded write did not reveal numbered additions")
assert(
  expanded_write_ranges[1].last - expanded_write_ranges[1].first
    > collapsed_write_ranges[1].last - collapsed_write_ranges[1].first,
  "expanded write range did not grow with visible additions"
)

local short_output =
  { type = "tool", name = "bash", state = "done", args = { command = "short" }, result = result("a\nb\nc") }
local short_lines = render_tools({ short_output })
assert(
  has_row(short_lines, "a") and has_row(short_lines, "b") and has_row(short_lines, "c"),
  "short completed output is missing"
)
assert(not rendered_text(short_lines):find("hidden", 1, true), "short completed output was collapsed")

local pending_output = {
  type = "tool",
  name = "bash",
  state = "pending",
  args = { command = "stream" },
  result = result(table.concat(bash_lines, "\n")),
}
local pending_lines = render_tools({ pending_output })
assert(
  has_row(pending_lines, "line 12") and not has_row(pending_lines, "line 1"),
  "pending output did not retain its tail"
)
local failed_output = vim.tbl_extend("force", {}, pending_output, { state = "done", error = true })
local failed_lines = render_tools({ failed_output })
assert(
  has_row(failed_lines, "line 12") and rendered_text(failed_lines):find("lines hidden", 1, true),
  "failed output tail is missing"
)

local expanded_output_lines = {}
for index = 1, 245 do
  table.insert(expanded_output_lines, "expanded " .. index)
end
local capped_lines = render_tools({
  {
    type = "tool",
    name = "bash",
    state = "done",
    expanded = true,
    args = { command = "large output" },
    result = result(table.concat(expanded_output_lines, "\n")),
  },
})
local capped_text = rendered_text(capped_lines)
assert(capped_text:find("expanded 239", 1, true), "expanded output safety cap removed retained rows")
assert(capped_text:find("… 6 more lines", 1, true), "expanded output safety cap marker is inaccurate")
assert(not capped_text:find("expanded 240", 1, true), "expanded output exceeded its renderer safety cap")

local metadata_tools = {
  {
    type = "tool",
    name = "bash",
    state = "done",
    args = { command = "released" },
    output_released = true,
    result = result(nil),
  },
  {
    type = "tool",
    name = "bash",
    state = "done",
    args = { command = "client truncated" },
    args_truncated = true,
    args_omitted_bytes = 2048,
    result = result("tail", {
      clientTruncated = true,
      clientRetainedBytes = 1024,
      clientOmittedBytes = 4096,
      truncated = true,
      fullOutputPath = "/tmp/pi-full-output.log",
    }),
  },
  {
    type = "tool",
    name = "read",
    state = "done",
    args = { path = "large.txt" },
    args_truncated = true,
    args_released = true,
    result = result("tail", { clientTruncated = true, clientOmittedBytes = 1024 }),
  },
  {
    type = "tool",
    name = "custom-image-result",
    state = "done",
    args = {},
    result = { content = { { type = "omitted", reason = "image_limit" } } },
  },
}
local metadata_lines, metadata_marks, metadata_ranges = render_tools(metadata_tools)
local metadata_text = rendered_text(metadata_lines)
for _, expected in ipairs({
  "Earlier output released from memory",
  "Client tool input limit omitted 2.0 KiB",
  "Client retained the last 1.0 KiB; 4.0 KiB omitted",
  "Full output: /tmp/pi-full-output.log",
  "Earlier tool input released from memory",
  "Client output limit omitted 1.0 KiB",
  "[Image omitted: payload exceeded the client tool output limit]",
}) do
  assert(metadata_text:find(expected, 1, true), "retention metadata is missing: " .. expected)
end
assert(highlight_set(metadata_marks).PiToolOmitted, "retention metadata highlight is missing")
assert_ranges(metadata_lines, metadata_ranges, metadata_tools)

local lua_parser_available = pcall(function()
  local parser = vim.treesitter.get_string_parser("local value = true", "lua")
  assert(parser:parse()[1], "tool renderer Lua parser probe returned no syntax tree")
  assert(vim.treesitter.query.get("lua", "highlights"), "tool renderer Lua highlight probe returned no query")
end)
local code_lines, code_marks, code_ranges = render_tools({
  {
    type = "tool",
    id = "read-lua",
    name = "read",
    state = "done",
    expanded = true,
    args = { path = "lua/example.lua", offset = 1 },
    result = result("local value = true\nreturn value"),
  },
})
assert(rendered_text(code_lines):find("local value = true", 1, true), "expanded Lua read is missing")
assert(
  rendered_text(code_lines):find("1 │ local value = true", 1, true)
    and rendered_text(code_lines):find("2 │ return value", 1, true),
  "expanded Lua read is missing file line numbers"
)
local code_highlights = highlight_set(code_marks, code_ranges[1])
assert(code_highlights.PiCodeLineNumber, "expanded read is missing its semantic line-number gutter")
if lua_parser_available then
  assert(code_highlights["@keyword.lua"], "expanded Lua read is missing keyword highlighting")
  assert(code_highlights["@boolean.lua"], "expanded Lua read is missing boolean highlighting")
end

local offset_lines, offset_marks, offset_ranges = render_tools({
  {
    type = "tool",
    id = "read-offset",
    name = "read",
    state = "done",
    expanded = true,
    args = { path = "lua/offset.lua", offset = 98, limit = 3 },
    result = result("first\nsecond\nthird\n\n[20 more lines in file. Use offset=101 to continue.]"),
  },
})
local offset_text = rendered_text(offset_lines)
assert(
  offset_text:find(" 98 │ first", 1, true)
    and offset_text:find(" 99 │ second", 1, true)
    and offset_text:find("100 │ third", 1, true),
  "read offset did not produce accurate stable-width file line numbers"
)
assert(
  not offset_text:find("101 │", 1, true)
    and offset_text:find("20 more lines in file", 1, true)
    and highlight_set(offset_marks, offset_ranges[1]).PiToolOmitted,
  "read continuation notice was presented as file content"
)

local completed_edit_lines, completed_edit_marks, completed_edit_ranges = render_tools({
  {
    type = "tool",
    id = "edit-completed",
    name = "edit",
    state = "done",
    expanded = true,
    args = { path = "lua/completed.lua", oldText = "old argument", newText = "new argument" },
    result = result("Successfully replaced 1 block", {
      diff = table.concat({
        "  41 local before = true",
        "- 42 local old = true",
        "+ 42 local ready = true",
        "  43 return ready",
      }, "\n"),
      firstChangedLine = 42,
    }),
  },
})
local completed_edit_text = rendered_text(completed_edit_lines)
assert(
  completed_edit_text:find("  41 │ local before = true", 1, true)
    and completed_edit_text:find("- 42 │ local old = true", 1, true)
    and completed_edit_text:find("+ 42 │ local ready = true", 1, true)
    and completed_edit_text:find("  43 │ return ready", 1, true),
  "completed edit did not render Pi's authoritative numbered diff"
)
assert(
  not completed_edit_text:find("old argument", 1, true) and not completed_edit_text:find("new argument", 1, true),
  "completed edit ignored its authoritative result diff"
)
local completed_edit_highlights = highlight_set(completed_edit_marks, completed_edit_ranges[1])
assert(
  completed_edit_highlights.PiDiffDelete
    and completed_edit_highlights.PiDiffAdd
    and completed_edit_highlights.PiDiffDeleteLine
    and completed_edit_highlights.PiDiffAddLine
    and completed_edit_highlights.PiCodeLineNumber,
  "completed edit diff lost symbol, color, or context gutter semantics"
)

local long_command = string.rep("界", 40)
local narrow_tools = {
  core_tools[1],
  { type = "tool", name = "bash", state = "pending", args = { command = long_command }, result = result(nil) },
  {
    type = "tool",
    name = "write",
    state = "done",
    duration_ms = 12000,
    args = { path = "deep/path/new.lua", content = "ok" },
    result = result(nil),
  },
}
local narrow_lines = render_tools(narrow_tools, { width = 42 })
local narrow_text = rendered_text(narrow_lines)
assert(narrow_text:find("Edited  example.lua", 1, true), "narrow edit header did not collapse its path")
assert(narrow_text:find("+1 -1", 1, true), "narrow edit header lost diff statistics")
assert(narrow_text:find("Wrote  new.lua", 1, true), "narrow write header did not collapse its path")
assert(not narrow_text:find("12.0s", 1, true), "narrow edit/write header retained lower-priority duration")
assert(narrow_text:find("◌ Running", 1, true), "narrow running tool lost its status and primary verb")
assert_width(narrow_lines, 42)

local hidden_tool_ranges = select(
  3,
  renderer.render({
    { type = "user", text = "run" },
    { type = "tool", name = "bash", state = "done", args = { command = "hidden" }, result = result("done") },
    { type = "assistant", message = { content = { { type = "text", text = "answer" } }, stopReason = "stop" } },
  }, {
    width = 80,
    collapse_processes = true,
    process_active = false,
    process_expanded = false,
  })
)
assert(#hidden_tool_ranges == 0, "collapsed process exposed stale tool ranges")

print("render_tools_spec: ok")
