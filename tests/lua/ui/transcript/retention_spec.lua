local retention = require("pi.ui.transcript.retention")

assert(retention.total_bytes({
  non_tool = 10,
  tool = 20,
  projection = 30,
  reasoning_buffer = "four",
  reasoning_header = "five!",
}) == 69, "retained byte total omitted an owner")
assert(retention.total_bytes({ non_tool = -10, tool = "invalid" }) == 0, "invalid counters were not normalized")

local completed = { type = "tool", state = "done", id = "completed" }
local pending = { type = "tool", state = "pending", id = "pending" }
local old_user = { type = "user", text = "old" }
local streaming = { type = "assistant" }
local actions = retention.candidates({ completed, pending, old_user, streaming }, streaming)

local expected = {
  { "tool_output", completed },
  { "tool_args", completed },
  { "tool_args_full", completed },
  { "body", old_user },
  { "tool_output", completed },
  { "tool_args", completed },
  { "tool_args_full", completed },
  { "tool_output", pending },
  { "tool_args", pending },
  { "tool_args_full", pending },
  { "body", old_user },
  { "body", streaming },
}
assert(#actions == #expected, "retention candidate count changed")
for index, action in ipairs(actions) do
  assert(action.kind == expected[index][1] and action.item == expected[index][2], "retention release order changed")
end

print("transcript_retention_spec: ok")
