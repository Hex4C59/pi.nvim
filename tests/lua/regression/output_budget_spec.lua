local config = require("pi.config")
local chat_module = require("pi.ui.chat")
local Chat = chat_module.Chat

config.setup({
  output = {
    live_max_bytes = 1024,
    live_max_lines = 10,
    max_chunks = 8,
    tool_max_bytes = 2048,
    transcript_max_bytes = 4096,
    render_interval_ms = 50,
  },
})

local chat = Chat.new(vim.fn.getcwd() .. "/output-budget")
local huge = string.rep("a", 10 * 1024 * 1024) .. "TAIL"
chat:start_tool("large-stream", "bash", { command = "large" })
chat:append_bash_delta("large-stream", huge)
local live_stats = chat.tools_by_id["large-stream"].bash_buffer:stats()
assert(live_stats.retained_bytes <= 1024 and live_stats.chunks <= 8, "single Bash delta escaped live limits")
chat:end_bash("large-stream", {
  output = "server truncated",
  truncated = false,
  fullOutputPath = "/tmp/pi-output.log",
  exitCode = 0,
}, false)
local streamed = chat.tools_by_id["large-stream"]
local streamed_text = chat_module.text_content(streamed.result.content)
assert(#streamed_text <= 1024 and streamed_text:sub(-4) == "TAIL", "Bash stream did not retain its bounded tail")
assert(streamed.result.details.clientTruncated, "client Bash truncation was not recorded")
assert(streamed.result.details.clientOmittedBytes > 0, "client omitted byte count is missing")
assert(streamed.result.details.fullOutputPath == "/tmp/pi-output.log", "full output path was lost")
assert(streamed.result.details.output == nil, "full Bash output leaked into result details")

chat:start_tool("many-deltas", "bash", { command = "many" })
for _ = 1, 10000 do
  chat:append_bash_delta("many-deltas", "x")
end
local many_stats = chat.tools_by_id["many-deltas"].bash_buffer:stats()
assert(many_stats.retained_bytes <= 1024 and many_stats.chunks <= 8, "small Bash deltas created unbounded state")
chat:end_bash("many-deltas", { exitCode = 0 }, false)

chat:start_tool("final-only", "bash", { command = "final" })
chat:end_bash("final-only", { output = huge, exitCode = 0 }, false)
local final = chat.tools_by_id["final-only"]
assert(#chat_module.text_content(final.result.content) <= 1024, "large final Bash output bypassed live limits")
assert(final.result.details.clientTruncated, "final-only client truncation was not recorded")

chat:start_tool("generic", "read", { path = "large.txt" })
chat:end_tool("generic", { content = { { type = "text", text = huge } } }, false)
local generic = chat.tools_by_id.generic
assert(#chat_module.text_content(generic.result.content) <= 2048, "generic tool escaped its per-tool limit")
assert(generic.result.details.clientTruncated, "generic tool truncation was not recorded")

chat:start_tool("image", "read", { path = "large.png" })
chat:end_tool("image", {
  content = { { type = "image", mimeType = "image/png", data = string.rep("x", 4096) } },
}, false)
local image = chat.tools_by_id.image
assert(image.result.content[1].clientOmitted, "large image payload was not replaced with an omitted marker")

chat:start_tool("large-write", "write", { path = "large.txt", content = huge })
local large_write = chat.tools_by_id["large-write"]
assert((large_write.args_retained_bytes or 0) <= 2048, "large write arguments escaped the per-tool limit")
assert(#(large_write.args.content or "") <= 2048, "large write content remained fully retained")
assert(large_write.args_truncated, "large write argument truncation was not recorded")
chat:end_tool("large-write", { content = { { type = "text", text = huge } } }, false)
assert(
  (large_write.args_retained_bytes or 0) + (large_write.retained_bytes or 0) <= 2048,
  "tool arguments and result did not share one per-tool budget"
)

local many_values = {}
for index = 1, 100000 do
  many_values[index] = index
end
chat:start_tool("large-table", "write", { path = "large.txt", values = many_values })
local large_table = chat.tools_by_id["large-table"]
assert(vim.tbl_count(large_table.args.values) <= 2046, "flat scalar arguments escaped the node limit")
assert(large_table.args_truncated, "argument node truncation was not recorded")

local budget = Chat.new(vim.fn.getcwd() .. "/transcript-budget")
for index = 1, 3 do
  local id = "tool-" .. index
  budget:start_tool(id, "read", { path = id })
  budget:end_tool(id, { content = { { type = "text", text = string.rep(tostring(index), 2048) } } }, false)
end
assert(budget.tool_retained_bytes <= 4096, "transcript tool output budget was exceeded")
assert(budget.tools_by_id["tool-1"].output_released, "oldest completed tool body was not released")
assert(not budget.tools_by_id["tool-3"].output_released, "newest tool body was released first")

budget:start_tool("pending", "read", { path = "pending" })
budget:update_tool("pending", { content = { { type = "text", text = string.rep("p", 2048) } } })
budget:start_tool("latest", "read", { path = "latest" })
budget:end_tool("latest", { content = { { type = "text", text = string.rep("l", 2048) } } }, false)
assert(not budget.tools_by_id.pending.output_released, "pending tool was evicted by transcript budget")

for index = 1, 4 do
  budget:start_tool("write-" .. index, "write", { path = "write-" .. index, content = string.rep("w", 2048) })
end
assert(budget.tool_retained_bytes <= 4096, "pending tool arguments escaped the transcript budget")
assert(budget.tools_by_id["write-1"].args_released, "oldest tool arguments were not released first")

local lines = require("pi.ui.render").render(budget.items, {
  hide_thinking = true,
  tools_expanded = true,
  collapse_processes = false,
  width = 100,
})
local rendered = table.concat(lines, "\n")
assert(rendered:find("Earlier output released from memory", 1, true), "released output marker was not rendered")

budget:clear()
assert(budget.tool_retained_bytes == 0 and #budget.items == 0, "Chat.clear did not release output accounting")

local throttled = Chat.new(vim.fn.getcwd() .. "/render-throttle")
throttled.buf = vim.api.nvim_create_buf(false, true)
local renders = 0
throttled._render_transcript = function()
  renders = renders + 1
end
throttled:start_tool("throttle", "bash", { command = "many" })
renders = 0
for _ = 1, 100 do
  throttled:append_bash_delta("throttle", "x")
end
assert(
  vim.wait(500, function()
    return renders > 0
  end, 10),
  "scheduled Bash render never ran"
)
assert(renders == 1, "high-frequency Bash updates were not coalesced")

print("output_budget_spec: ok")
