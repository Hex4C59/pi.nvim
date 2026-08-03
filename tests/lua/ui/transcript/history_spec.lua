local history = require("pi.ui.transcript.history")

local messages = {
  { role = "user", content = { { type = "text", text = "question" } } },
  {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "reasoning" },
      { type = "text", text = "answer" },
      { type = "toolCall", id = "read-1", name = "read", arguments = { path = "README.md" } },
    },
  },
  { role = "toolResult", toolCallId = "read-1", content = { { type = "text", text = "result" } } },
  { role = "bashExecution", timestamp = 7, command = "pwd", output = "/tmp", exitCode = 0 },
  { role = "unsupported", content = "ignored" },
  false,
}
local authoritative = vim.deepcopy(messages)
local events = history.events(messages)
assert(vim.deep_equal(messages, authoritative), "history event projection mutated authoritative messages")
local kinds = {}
for _, event in ipairs(events) do
  table.insert(kinds, event.kind)
end
assert(
  vim.deep_equal(kinds, { "user", "assistant", "tool_call", "tool_result", "bash" }),
  "history event order or filtering changed"
)
assert(events[1].text == "question", "history user text was not projected")
assert(events[3].block.id == "read-1", "history tool-call identity was lost")

local replayed = {}
history.replay(messages, {
  user = function()
    table.insert(replayed, "user")
  end,
  tool_result = function()
    table.insert(replayed, "tool_result")
  end,
  bash = function()
    table.insert(replayed, "bash")
  end,
})
assert(vim.deep_equal(replayed, { "user", "tool_result", "bash" }), "history replay did not dispatch handlers in order")

print("transcript_history_spec: ok")
