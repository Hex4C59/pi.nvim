local text_content = require("pi.message").text_content
local Transcript = require("pi.ui.transcript").Transcript

local function new_transcript(overrides)
  local output = vim.tbl_extend("force", {
    live_max_bytes = 64,
    live_max_lines = 4,
    max_chunks = 3,
    tool_max_bytes = 128,
    transcript_max_bytes = 512,
  }, overrides or {})
  local now = 0
  local transcript = Transcript.new({
    output = output,
    images = { attachment_max_count = 2 },
    clock = function()
      now = now + 1000000
      return now
    end,
  })
  return transcript
end

local transcript = new_transcript()
local huge = string.rep("a", 4096) .. "TAIL"
transcript:start_tool("single", "bash", { command = "single" })
transcript:append_bash_delta("single", huge)
local stats = transcript:find_tool("single").bash_buffer:stats()
assert(stats.retained_bytes <= 64 and stats.chunks <= 3, "single Bash delta escaped live limits")
transcript:end_bash("single", { exitCode = 0 }, false)
local single = transcript:find_tool("single")
assert(text_content(single.result.content):sub(-4) == "TAIL", "Bash tail was not retained")
assert(single.result.details.clientTruncated, "Bash truncation metadata is missing")

transcript:start_tool("many", "bash", { command = "many" })
for _ = 1, 1000 do
  transcript:append_bash_delta("many", "x")
end
stats = transcript:find_tool("many").bash_buffer:stats()
assert(stats.retained_bytes <= 64 and stats.chunks <= 3, "small Bash deltas created unbounded chunks")
transcript:end_bash("many", { exitCode = 0 }, false)

transcript:start_tool("final", "bash", { command = "final" })
transcript:end_bash("final", { output = huge, exitCode = 0 }, false)
local final = transcript:find_tool("final")
assert(#text_content(final.result.content) <= 64, "final-only Bash output bypassed live limits")
assert(final.result.details.clientTruncated, "final-only Bash truncation was not recorded")

local replacement = new_transcript()
replacement:start_tool("replace", "read", { path = "fixture.txt" })
replacement:update_tool("replace", { content = { { type = "text", text = "first partial" } } })
replacement:update_tool("replace", { content = { { type = "text", text = "second partial" } } })
local replaced = text_content(replacement:find_tool("replace").result.content)
assert(replaced == "second partial", "generic partial tool result was appended instead of replaced")

local shared = new_transcript({ transcript_max_bytes = 2048 })
shared:start_tool("write", "write", { path = "fixture.txt", content = string.rep("i", 110) })
shared:end_tool("write", { content = { { type = "text", text = string.rep("o", 110) } } }, false)
local write = shared:find_tool("write")
assert(
  (write.args_retained_bytes or 0) + (write.retained_bytes or 0) <= 128,
  "tool arguments and result did not share their byte budget"
)

local eviction = new_transcript({ tool_max_bytes = 100, transcript_max_bytes = 150 })
eviction:start_tool("pending", "read", { path = "pending" })
eviction:update_tool("pending", { content = { { type = "text", text = string.rep("p", 80) } } })
eviction:start_tool("done", "read", { path = "done" })
eviction:end_tool("done", { content = { { type = "text", text = string.rep("d", 80) } } }, false)
assert(not eviction:find_tool("pending").output_released, "pending output was released before completed output")
assert(eviction:find_tool("done").output_released, "completed output was not released first")

local oldest = new_transcript({ tool_max_bytes = 100, transcript_max_bytes = 170 })
for index = 1, 3 do
  local id = "oldest-" .. index
  oldest:start_tool(id, "read", { path = id })
  oldest:end_tool(id, { content = { { type = "text", text = string.rep(tostring(index), 80) } } }, false)
end
assert(oldest:find_tool("oldest-1").output_released, "oldest completed output was not released first")
assert(not oldest:find_tool("oldest-3").output_released, "newest completed output was released first")

local image = new_transcript()
image:start_tool("image", "read", { path = "large.png" })
image:end_tool("image", {
  content = { { type = "image", mimeType = "image/png", data = string.rep("x", 1024) } },
}, false)
assert(image:find_tool("image").result.content[1].clientOmitted, "oversized image was not replaced by an omission")

local history = new_transcript({ transcript_max_bytes = 2048 })
local messages = {
  { role = "user", content = { { type = "text", text = "question" } } },
  {
    role = "assistant",
    content = {
      { type = "text", text = "answer" },
      { type = "toolCall", id = "history-tool", name = "read", arguments = { path = "a.txt" } },
    },
  },
  { role = "toolResult", toolCallId = "history-tool", content = { { type = "text", text = "result" } } },
}
local authoritative = vim.deepcopy(messages)
history:render_history(messages)
assert(vim.deep_equal(messages, authoritative), "history projection mutated authoritative messages")
assert(#history.items == 3, "history reconstruction produced the wrong item order")
assert(history.items[1].type == "user" and history.items[2].type == "assistant", "history roles changed")
assert(history:find_tool("history-tool").state == "done", "history tool result was not correlated")

local tolerant = new_transcript()
tolerant:update_tool("unknown", { content = {} })
tolerant:end_tool("unknown", { content = {} }, false)
tolerant:append_bash_delta("unknown", "ignored")
assert(#tolerant.items == 0, "out-of-order unknown tool events created display state")
tolerant:start_tool("duplicate", "read", { path = "first" })
local identity = tolerant:find_tool("duplicate")._pi_id
tolerant:start_tool("duplicate", "read", { path = "second" })
assert(#tolerant.items == 1, "duplicate tool start created a second item")
assert(tolerant:find_tool("duplicate")._pi_id == identity, "duplicate tool start changed item identity")
assert(tolerant:find_tool("duplicate").args.path == "second", "duplicate tool start did not refresh arguments")

print("transcript_spec: ok")
