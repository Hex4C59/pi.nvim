local renderer = require("pi.ui.render")
local welcome = require("pi.ui.render.welcome")

local function assert_shape(lines, marks, width)
  assert(#lines > 0, "welcome must render at least one line")
  for _, line in ipairs(lines) do
    assert(vim.fn.strdisplaywidth(line) == width, "welcome line width changed")
    assert(not line:find("[\r\n]"), "welcome line contains an embedded newline")
  end

  for _, mark in ipairs(marks) do
    assert(type(mark.row) == "number" and mark.row >= 0 and mark.row < #lines, "welcome mark row is out of range")
    assert(type(mark.start_col) == "number" and mark.start_col >= 0, "welcome mark start column is invalid")
    assert(type(mark.end_col) == "number" and mark.end_col >= mark.start_col, "welcome mark columns are reversed")
    assert(mark.end_col <= #lines[mark.row + 1], "welcome mark exceeds its rendered line")
  end
end

local base_opts = {
  width = 80,
  model = "gpt-5.6-sol",
  thinking = "high",
  root = "/tmp/pi.nvim",
  permission = "confirm",
}
local welcome_lines, welcome_marks = renderer.render_welcome(base_opts)
local owner_lines, owner_marks = welcome.render(base_opts)
assert(vim.deep_equal(welcome_lines, owner_lines), "render facade no longer delegates welcome lines")
assert(vim.deep_equal(welcome_marks, owner_marks), "render facade no longer delegates welcome marks")

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
assert(welcome_text:find("manual", 1, true), "welcome permission mode is missing")
assert(not welcome_text:find("Enter send", 1, true), "welcome send hint should be removed")
assert(not welcome_text:find("Ctrl-J", 1, true), "welcome newline hint should be removed")
assert(not welcome_text:find("/hotkeys", 1, true), "welcome keybinding hint should be removed")
assert(not welcome_text:find("/commands", 1, true), "welcome should not advertise the redundant command browser")
assert(#welcome_lines == 9, "wide welcome retained unnecessary vertical padding")
assert(
  welcome_lines[#welcome_lines - 1]:find("/tmp/pi.nvim", 1, true),
  "wide welcome project row is not adjacent to the bottom border"
)
local wide_title_prefix = welcome_lines[1]:match("^(.-)┬")
assert(
  wide_title_prefix and vim.fn.strdisplaywidth(wide_title_prefix) == 29,
  "wide welcome brand column did not use the compact proportion"
)
assert_shape(welcome_lines, welcome_marks, 80)

local highlights = {}
for _, mark in ipairs(welcome_marks) do
  if mark.highlight then
    highlights[mark.highlight] = true
  end
end
for index = 1, 4 do
  assert(highlights["PiWelcomeLogo" .. index], "welcome logo color segment is missing")
end
for _, group in ipairs({
  "PiWelcomeTitle",
  "PiWelcomeAgent",
  "PiWelcomeNeovim",
  "PiWelcomeSection",
  "PiWelcomeModelValue",
  "PiWelcomeThinkingValue",
  "PiWelcomeProjectValue",
  "PiWelcomePermissionValue",
}) do
  assert(highlights[group], "welcome semantic highlight is missing: " .. group)
end
assert(not highlights.PiWelcomeKey, "removed welcome shortcut highlight is still present")

for _, width in ipairs({ 20, 42, 71, 72, 80 }) do
  local lines, marks = renderer.render_welcome({
    width = width,
    model = "模型-with-a-deliberately-long-name",
    thinking = "",
    root = "/tmp/界面/a/deliberately/long/project/path/pi.nvim",
    permission = "full",
  })
  assert_shape(lines, marks, width)
  assert(#lines == 9, "welcome responsive height changed")
  assert((lines[1]:find("┬", 1, true) ~= nil) == (width >= 72), "welcome responsive breakpoint changed")
  if width >= 32 and width < 72 then
    local compact = table.concat(lines, "\n")
    assert(compact:find("PI · agent for Neovim", 1, true), "compact welcome brand is missing")
    assert(not compact:find("████", 1, true), "compact welcome retained the four-line logo")
    assert(lines[#lines - 1]:find("/tmp", 1, true), "compact project row is not next to the border")
  end
end

local permission_labels = {
  { mode = "syncing", expected = "syncing" },
  { mode = "confirm", expected = "manual" },
  { mode = "manual", expected = "manual" },
  { mode = "read-only", expected = "workspace read only" },
  { mode = "plan", expected = "plan" },
  { mode = "auto", expected = "auto" },
  { mode = "acceptEdits", expected = "accept edits" },
}
for _, case in ipairs(permission_labels) do
  local lines, marks = renderer.render_welcome({
    width = 72,
    model = "loading",
    thinking = "",
    root = "/tmp/pi.nvim",
    permission = case.mode,
  })
  local rendered = table.concat(lines, "\n")
  assert(rendered:find("connecting...", 1, true), "loading model label changed")
  assert(rendered:find(case.expected, 1, true), "permission label changed: " .. case.mode)
  assert_shape(lines, marks, 72)
end

local read_only_lines, read_only_marks = renderer.render_welcome({
  width = 80,
  model = "fixture",
  thinking = "off",
  root = "/tmp/pi.nvim",
  permission = "full",
  security = "read-only",
})
assert(
  table.concat(read_only_lines, "\n"):find("workspace read only", 1, true),
  "read-only security state must override the permission label"
)
assert_shape(read_only_lines, read_only_marks, 80)

print("render_welcome_spec: ok")
