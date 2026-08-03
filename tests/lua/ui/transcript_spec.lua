local text_content = require("pi.message").text_content
local Transcript = require("pi.ui.transcript").Transcript

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local function image_block()
  return { type = "image", mimeType = "image/png", data = png_base64, alt = "pixel" }
end

local function new_transcript(overrides)
  local output = vim.tbl_extend("force", {
    live_max_bytes = 64,
    live_max_lines = 4,
    max_chunks = 3,
    tool_max_bytes = 128,
    transcript_max_bytes = 512,
  }, overrides or {})
  local now = 0
  local observed = { changes = {}, invalidations = {}, input_changes = 0 }
  local transcript = Transcript.new({
    output = output,
    images = { attachment_max_count = 2 },
    clock = function()
      now = now + 1000000
      return now
    end,
    on_change = function(immediate, item)
      table.insert(observed.changes, { immediate = immediate, item = item })
    end,
    on_invalidate = function(item)
      table.insert(observed.invalidations, item or false)
    end,
    on_input_change = function()
      observed.input_changes = observed.input_changes + 1
    end,
  })
  return transcript, observed
end

local user, user_observed = new_transcript({ transcript_max_bytes = 4096 })
local source_image = image_block()
local structured = { source_image, { type = "text", text = "caller-owned" } }
local authoritative_structured = vim.deepcopy(structured)
user:add_user("hello", structured)
local user_item = user.items[1]
assert(user_item.type == "user" and user_item.text == "hello", "text user projection changed")
assert(user_item.content[1] ~= source_image, "user projection retained an authoritative image block")
assert(user_item.content[1].data == nil, "localized display image retained source base64")
assert(vim.deep_equal(structured, authoritative_structured), "user projection mutated caller content")
assert(user_item.body_retained_bytes >= #user_item.text, "user body accounting omitted text")
assert(user_observed.changes[1].immediate == true, "user addition did not request an immediate render")
local valid, _, payload_bytes = user:validate_image_attachments({ source_image })
assert(valid and payload_bytes == #png_base64, "valid image attachment was rejected or miscounted")
local too_many, count_error = user:validate_image_attachments({ source_image, source_image, source_image })
assert(not too_many and count_error:find("Too many", 1, true), "attachment count limit was not enforced")
local too_large = new_transcript({ transcript_max_bytes = 512 })
too_large.image_options = { attachment_max_count = 2, attachment_max_bytes = 8 }
local size_ok, size_error = too_large:validate_image_attachments({ source_image })
assert(not size_ok and size_error:find("too large", 1, true), "attachment payload limit was not enforced")
local localized = user:localize_images({ source_image })
assert(localized[1] ~= source_image and localized[1].data == nil, "localize_images retained caller-owned payload")
assert(vim.deep_equal(source_image, authoritative_structured[1]), "localize_images mutated its source block")
user:release_image(localized[1])
assert(localized[1]._pi_image == nil, "explicit localized image release retained presentation state")
local owned_user_image = user_item.content[1]
user:clear()
assert(owned_user_image._pi_image == nil, "clear did not release user image ownership")
assert(#user.items == 0 and user.non_tool_retained_bytes == 0, "clear did not reset user model state")

local truncated_user = new_transcript({ transcript_max_bytes = 8 })
truncated_user:add_user("0123456789")
assert(truncated_user.items[1].body_truncated, "user text truncation marker is missing")
assert(truncated_user.items[1].body_omitted_bytes == 2, "user omitted byte count changed")

local assistant, assistant_observed = new_transcript({ transcript_max_bytes = 512 })
local starting_message = {
  role = "assistant",
  content = { { type = "thinking", thinking = "private" }, { type = "text", text = "draft" } },
}
local authoritative_message = vim.deepcopy(starting_message)
assistant:start_assistant(starting_message)
local assistant_item = assistant.streaming_assistant
assert(assistant_item and assistant_item == assistant.items[1], "assistant streaming identity is not unique")
assert(assistant_item.had_thinking, "assistant thinking presence was not recorded")
assistant:update_assistant(starting_message, { type = "thinking_start" })
assistant:update_assistant(starting_message, { type = "thinking_delta", delta = "**Planning**" })
assert(assistant.reasoning_header == "Planning", "complete reasoning header was not extracted")
assistant:update_assistant(starting_message, { type = "thinking_delta", delta = "**Incomplete" })
assert(assistant.reasoning_header == "Planning", "incomplete reasoning header replaced the active label")
assistant:update_assistant(starting_message, { type = "text_delta", delta = "public" })
assert(assistant.reasoning_header == nil and assistant.reasoning_buffer == "", "public text retained reasoning status")
local ending_message = { role = "assistant", content = {}, stopReason = "error", errorMessage = "failed" }
assistant:end_assistant(ending_message)
assert(assistant.streaming_assistant == nil, "assistant streaming state survived end")
assert(assistant_item.message.stopReason == "error" and assistant_item.message.errorMessage == "failed")
assert(assistant_item.duration_ms >= 1, "assistant duration was not finalized")
assert(vim.deep_equal(starting_message, authoritative_message), "assistant lifecycle mutated an input message")
assert(assistant_observed.input_changes >= 3, "assistant reasoning/input notifications are missing")
assert(assistant_observed.changes[1].immediate and assistant_observed.changes[#assistant_observed.changes].immediate)

local empty_assistant = new_transcript()
empty_assistant:end_assistant({ role = "assistant", content = {}, stopReason = "stop" })
assert(#empty_assistant.items == 1 and empty_assistant.items[1].message.stopReason == "stop")

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
local partial_result = { content = { { type = "text", text = "first partial" } } }
local authoritative_partial = vim.deepcopy(partial_result)
replacement:update_tool("replace", partial_result)
replacement:update_tool("replace", { content = { { type = "text", text = "second partial" } } })
local replaced = text_content(replacement:find_tool("replace").result.content)
assert(replaced == "second partial", "generic partial tool result was appended instead of replaced")
assert(vim.deep_equal(partial_result, authoritative_partial), "generic tool projection mutated its input result")
replacement:start_tool("custom", "unregistered-tool", { payload = { nested = "value" } })
replacement:end_tool("custom", { content = { { type = "text", text = "failed" } } }, true)
assert(replacement:find_tool("custom").name == "unregistered-tool", "unknown tool name was inferred or replaced")
assert(replacement:find_tool("custom").error == true, "generic tool error state was lost")

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

local bash_metadata = new_transcript({ transcript_max_bytes = 2048 })
bash_metadata:start_tool("streamed", "bash", { command = "printf chunks" })
bash_metadata:append_bash_delta("streamed", "first-")
bash_metadata:append_bash_delta("streamed", "second")
bash_metadata:materialize_pending_bash()
assert(text_content(bash_metadata:find_tool("streamed").result.content) == "first-second")
assert(not bash_metadata:find_tool("streamed").bash_dirty, "pending Bash output was not materialized")
bash_metadata:end_bash("streamed", {
  output = "duplicated final echo",
  exitCode = 7,
  fullOutputPath = "/tmp/full-output.log",
  truncated = true,
}, true)
local streamed = bash_metadata:find_tool("streamed")
assert(text_content(streamed.result.content) == "first-second", "final Bash echo replaced streamed output")
assert(streamed.error and streamed.result.details.exitCode == 7, "Bash exit/error state was lost")
assert(streamed.result.details.fullOutputPath == "/tmp/full-output.log", "Pi full-output path was lost")
assert(streamed.result.details.output == nil, "Bash details duplicated output")

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

local rich_history = new_transcript({ transcript_max_bytes = 4096 })
local rich_messages = {
  { role = "user", content = { { type = "text", text = "turn one" }, image_block() } },
  {
    role = "assistant",
    content = { { type = "thinking", thinking = "private" }, { type = "text", text = "answer one" } },
    stopReason = "stop",
  },
  { role = "toolResult", toolCallId = "missing", content = { { type = "text", text = "ignored" } } },
  { role = "bashExecution", timestamp = 42, command = "false", output = "failure", exitCode = 1 },
  { role = "user", content = { { type = "text", text = "turn two" } } },
  { role = "assistant", content = {}, stopReason = "error", errorMessage = "history error" },
}
local authoritative_rich_history = vim.deepcopy(rich_messages)
rich_history:render_history(rich_messages)
assert(vim.deep_equal(rich_messages, authoritative_rich_history), "rich history projection mutated authoritative input")
assert(#rich_history.items == 5, "malformed/unmatched history changed projected item count")
assert(rich_history.items[1].content[1].data == nil, "history image retained source base64")
assert(rich_history:find_tool("bash-42").error, "history Bash error state was lost")
assert(rich_history.items[5].message.errorMessage == "history error", "history assistant error was lost")

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

local destroyable = new_transcript({ transcript_max_bytes = 4096 })
destroyable:add_user("image", { image_block() })
local destroy_image = destroyable.items[1].content[1]
destroyable:destroy()
destroyable:destroy()
assert(destroy_image._pi_image == nil, "destroy did not release image presentation state")
assert(#destroyable.items == 0 and next(destroyable.tools_by_id) == nil, "destroy did not reset indexes")

print("transcript_spec: ok")
