local renderer = require("pi.ui.render")

local function render(items, opts)
  return renderer.render(items, vim.tbl_extend("force", { width = 80 }, opts or {}))
end

local function rendered_text(lines)
  return table.concat(lines, "\n")
end

local function highlight_set(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark.highlight then
      result[mark.highlight] = true
    end
  end
  return result
end

local user_lines, user_marks = render({ { type = "user", text = "Review this\nand that" } })
local user_text = rendered_text(user_lines)
assert(user_text:find(" › Review this\n   and that", 1, true), "multiline user message lost its structural marker")
assert(not user_text:find("YOU", 1, true), "legacy user role label is still rendered")
local user_highlights = highlight_set(user_marks)
assert(user_highlights.PiUserMessageText, "user message semantic highlight is missing")
assert(user_highlights.PiUserLabel, "user structural marker highlight is missing")

local empty_user_lines = render({ { type = "user", text = "" } })
assert(vim.deep_equal(empty_user_lines, { " › " }), "empty user message no longer renders its structural row")

local image_block = { type = "image", mimeType = "image/png" }
local image_user = { type = "user", text = "caption", content = { image_block } }
local image_user_copy = vim.deepcopy(image_user)
local image_user_lines = render({ image_user })
local image_user_text = rendered_text(image_user_lines)
assert(image_user_text:find(" › caption", 1, true), "user image message lost its text")
assert(image_user_text:find("[Image: image/png]", 1, true), "user image message lost its text fallback")
assert(vim.deep_equal(image_user, image_user_copy), "message rendering mutated a user image block")

local released_user_lines = render({ { type = "user", text = "discarded", body_released = true } })
assert(
  rendered_text(released_user_lines):find("Earlier user message released from local memory", 1, true),
  "released user body marker is missing"
)
local truncated_user_lines = render({ { type = "user", text = "retained", body_truncated = true } })
assert(
  rendered_text(truncated_user_lines):find("Client transcript limit omitted part of this message", 1, true),
  "truncated user body marker is missing"
)

local public_lines = render({
  {
    type = "assistant",
    message = { content = { { type = "text", text = "Public answer" } }, stopReason = "stop" },
  },
})
local public_text = rendered_text(public_lines)
assert(public_text:find("Public answer", 1, true), "public assistant text is missing")
assert(not public_text:find("Thinking", 1, true), "assistant without thinking rendered thinking metadata")
assert(not public_text:find("◆ PI", 1, true), "legacy assistant role label is still rendered")
assert(not public_text:find("Error:", 1, true), "normal stop reason rendered an error")

local hidden_lines = render({
  {
    type = "assistant",
    duration_ms = 6100,
    message = {
      content = {
        { type = "thinking", thinking = "private reasoning" },
        { type = "text", text = "Final answer" },
      },
    },
  },
}, { hide_thinking = true })
local hidden_text = rendered_text(hidden_lines)
local thought_at = assert(hidden_text:find("Thought for 6.1s", 1, true), "hidden thinking duration is missing")
local answer_at = assert(hidden_text:find("Final answer", 1, true), "assistant answer is missing")
assert(thought_at < answer_at, "thinking metadata must precede public assistant content")
assert(not hidden_text:find("private reasoning", 1, true), "hidden thinking leaked into the transcript")

local visible_lines, visible_marks = render({
  {
    type = "assistant",
    duration_ms = 1000,
    message = {
      content = {
        { type = "thinking", thinking = "visible reasoning" },
        { type = "text", text = "Visible answer" },
      },
    },
  },
}, { hide_thinking = false })
local visible_text = rendered_text(visible_lines)
assert(visible_text:find("visible reasoning", 1, true), "requested thinking details are missing")
assert(
  visible_text:find("visible reasoning", 1, true) < visible_text:find("Visible answer", 1, true),
  "thinking order changed"
)
assert(highlight_set(visible_marks).PiThinkingText, "thinking semantic highlight is missing")

local hidden_thinking_only = render({
  {
    type = "assistant",
    message = { content = { { type = "thinking", thinking = "private only" } } },
  },
}, { hide_thinking = true, hide_thinking_meta = true })
assert(#hidden_thinking_only == 0, "fully hidden thinking-only message left an empty row")
local visible_thinking_only = render({
  {
    type = "assistant",
    message = { content = { { type = "thinking", thinking = "visible only" } } },
  },
}, { hide_thinking = false })
assert(rendered_text(visible_thinking_only):find("visible only", 1, true), "thinking-only message did not render")

local multiple_lines = render({
  {
    type = "assistant",
    message = {
      content = {
        { type = "text", text = "First block" },
        { type = "image", mimeType = "image/jpeg" },
        { type = "text", text = "Second block" },
      },
    },
  },
})
local multiple_text = rendered_text(multiple_lines)
assert(
  multiple_text:find("First block", 1, true) < multiple_text:find("Second block", 1, true),
  "assistant blocks reordered"
)
assert(multiple_text:find("[Image: image/jpeg]", 1, true), "assistant image block is missing")

local released_assistant_lines = render({ { type = "assistant", body_released = true, message = { content = {} } } })
assert(
  rendered_text(released_assistant_lines):find("Earlier assistant message released from local memory", 1, true),
  "released assistant body marker is missing"
)
local truncated_assistant_lines = render({
  {
    type = "assistant",
    body_truncated = true,
    message = { content = { { type = "text", text = "Retained answer" } } },
  },
})
assert(
  rendered_text(truncated_assistant_lines):find("Client transcript limit omitted part of this response", 1, true),
  "truncated assistant body marker is missing"
)

local one_line_error = render({
  { type = "assistant", message = { content = {}, stopReason = "error", errorMessage = "request failed" } },
})
assert(rendered_text(one_line_error):find(" Error: request failed", 1, true), "single-line assistant error is missing")
local multiline_error_lines, multiline_error_marks = render({
  {
    type = "assistant",
    message = { content = {}, stopReason = "error", errorMessage = "first line\r\nsecond line" },
  },
})
assert(
  rendered_text(multiline_error_lines):find(" Error: first line\n        second line", 1, true),
  "multiline assistant error was not split into separate rows"
)
assert(highlight_set(multiline_error_marks).PiToolError, "assistant error highlight is missing")

for index, line in ipairs(multiline_error_lines) do
  assert(not line:find("[\r\n]"), ("assistant error row %d contains an embedded newline"):format(index))
end

local status_lines, status_marks = render({ { type = "status", text = "indexing\r\nworkspace" } })
assert(rendered_text(status_lines):find("indexing workspace", 1, true), "multiline status was not normalized")
assert(highlight_set(status_marks).PiPanelMuted, "normal status highlight is missing")
local error_status_lines, error_status_marks = render({ { type = "status", text = "failed", error = true } })
assert(rendered_text(error_status_lines):find("failed", 1, true), "error status text is missing")
assert(highlight_set(error_status_marks).PiToolError, "error status highlight is missing")
local empty_status_lines = render({ { type = "status", text = "" } })
assert(#empty_status_lines == 0, "empty status message rendered a stray row")
local released_status_lines = render({ { type = "status", text = "discarded", body_released = true } })
assert(
  rendered_text(released_status_lines):find("Earlier status message released from local memory", 1, true),
  "released status body marker is missing"
)

for _, fixture in ipairs({
  {
    label = "assistant",
    item = {
      type = "assistant",
      message = { content = { { type = "text", text = "```lua\nlocal responsive = true\n```" } } },
    },
    opts = { width = 48 },
  },
  {
    label = "thinking",
    item = {
      type = "assistant",
      message = { content = { { type = "thinking", thinking = "```lua\nlocal responsive = true\n```" } } },
    },
    opts = { width = 64, hide_thinking = false },
  },
  {
    label = "status",
    item = { type = "status", text = "```lua\nlocal responsive = true\n```" },
    opts = { width = 96 },
  },
}) do
  local lines = render({ fixture.item }, fixture.opts)
  local code_line
  for _, line in ipairs(lines) do
    if line:find("local responsive = true", 1, true) then
      code_line = line
      break
    end
  end
  assert(code_line, fixture.label .. " code surface is missing")
  assert(
    vim.fn.strdisplaywidth(code_line) == fixture.opts.width - 1,
    fixture.label .. " code surface ignored the transcript width"
  )
end

for _, fixture_lines in ipairs({ user_lines, public_lines, hidden_lines, visible_lines, multiple_lines, status_lines }) do
  for _, line in ipairs(fixture_lines) do
    assert(not line:find("[\r\n]"), "message renderer emitted an embedded newline")
  end
end

print("render_messages_spec: ok")
