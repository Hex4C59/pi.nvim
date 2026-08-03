local engine = require("pi.ui.render.engine")
local renderer = require("pi.ui.render")

assert(renderer.split_lines("one\r\ntwo")[2] == "two", "render facade no longer delegates line splitting")
assert(
  renderer.result_text({ content = { { type = "text", text = "result" } } }) == "result",
  "render facade no longer delegates result text"
)
assert(renderer.format_duration(1200) == "1.2s", "render facade no longer delegates duration formatting")
assert(renderer.format_elapsed(12) == "12s", "render facade no longer delegates elapsed formatting")
assert(renderer.split_lines == engine.split_lines, "render facade replaced the engine text-helper owner")

local welcome_opts = {
  width = 80,
  model = "gpt-5.6-sol",
  thinking = "high",
  root = "/tmp/pi.nvim",
  permission = "confirm",
}
local welcome_lines, welcome_marks = renderer.render_welcome(welcome_opts)
local engine_welcome_lines, engine_welcome_marks = engine.render_welcome(welcome_opts)
assert(#welcome_lines > 0 and #welcome_marks > 0, "render facade welcome result is incomplete")
assert(vim.deep_equal(welcome_lines, engine_welcome_lines), "render facade changed delegated welcome lines")
assert(vim.deep_equal(welcome_marks, engine_welcome_marks), "render facade changed delegated welcome marks")

local function prepared_text(value)
  return {
    type = "text",
    text = value,
    _pi_markdown_images = {
      cache_key = "\0" .. value,
      blocks = {},
      by_line = {},
    },
  }
end

local image_block = {
  type = "image",
  mimeType = "image/png",
  path = "/tmp/facade-image.png",
  _pi_image = {
    mime_type = "image/png",
    prepared = {
      key = "facade-image",
      path = "/tmp/facade-image.png",
      width = 6,
      height = 3,
      description = "[Image: image/png 6x3]",
    },
  },
}
local items = {
  { type = "user", text = "First request" },
  {
    type = "assistant",
    duration_ms = 1000,
    message = {
      content = {
        { type = "thinking", thinking = "private first turn" },
        prepared_text("First response"),
      },
    },
  },
  {
    type = "tool",
    name = "bash",
    state = "done",
    duration_ms = 1000,
    args = { command = "first command" },
    result = { content = { { type = "text", text = "first output" } } },
  },
  { type = "user", text = "Second request" },
  {
    type = "assistant",
    _pi_id = "assistant:facade",
    message = {
      content = {
        prepared_text("**Assistant** response"),
        image_block,
      },
    },
  },
  {
    type = "tool",
    name = "read",
    state = "done",
    args = { path = "README.md" },
    result = { content = { { type = "text", text = "visible tool output" } } },
  },
}
local authoritative_items = vim.deepcopy(items)
local lines, marks, tool_ranges, process_ranges, images = renderer.render(items, {
  width = 80,
  collapse_processes = true,
  process_active = true,
  process_expanded = false,
  tools_expanded = false,
  image_terminal = true,
  welcome = welcome_opts,
})
local text = table.concat(lines, "\n")
assert(
  text:find("████████████", 1, true),
  "welcome component did not compose through the facade"
)
assert(text:find("First request", 1, true), "user message did not compose through the facade")
assert(text:find("First response", 1, true), "settled assistant response did not compose through the facade")
assert(text:find("Second request", 1, true), "second user turn did not compose through the facade")
assert(text:find("Assistant response", 1, true), "active assistant response did not compose through the facade")
assert(text:find("Read  README.md", 1, true), "active tool did not compose through the facade")
assert(#tool_ranges == 1 and tool_ranges[1].first <= tool_ranges[1].last, "tool ranges changed tuple position")
assert(
  #process_ranges == 1 and process_ranges[1].first <= process_ranges[1].last,
  "process ranges changed tuple position"
)
assert(#images == 1 and images[1].block == image_block, "image descriptors changed tuple position")

local highlights = {}
for _, mark in ipairs(marks) do
  if mark.highlight then
    highlights[mark.highlight] = true
  end
end
for _, group in ipairs({
  "PiWelcomeTitle",
  "PiUserMessageText",
  "PiMarkdownStrong",
  "PiToolSuccess",
  "PiProcessSummary",
  "PiImageSurface",
}) do
  assert(highlights[group], "composed semantic mark is missing: " .. group)
end
assert(vim.deep_equal(items, authoritative_items), "render facade mutated its structured input items")

print("render_spec: ok")
