local projection = require("pi.ui.transcript.projection")

local utf8 = "a界b"
local head, head_omitted = projection.utf8_head(utf8, 2)
assert(head == "a" and head_omitted == 4, "UTF-8 head split a multibyte character")
local tail, tail_omitted = projection.utf8_tail(utf8, 2)
assert(tail == "b" and tail_omitted == 4, "UTF-8 tail split a multibyte character")

assert(projection.extract_reasoning_header("prefix **  Plan   carefully  ** suffix") == "Plan carefully")
assert(projection.extract_reasoning_header("**incomplete") == nil, "incomplete reasoning header was accepted")

local args = {
  path = "src/file.lua",
  content = string.rep("x", 32),
  nested = { value = "kept", deeper = { value = "bounded" } },
}
local authoritative_args = vim.deepcopy(args)
local limited_args, retained, omitted = projection.limited_tool_args(args, 12, 5)
assert(vim.deep_equal(args, authoritative_args), "argument projection mutated authoritative arguments")
assert(limited_args ~= args and retained <= 12 and omitted > 0, "argument byte/node limits were not applied")
assert(limited_args.path == "src/file.lua", "priority argument was not retained first")

local result = {
  content = { { type = "text", text = "0123456789" } },
  details = { output = "large echo", fullOutputPath = "/tmp/full.log" },
}
local authoritative_result = vim.deepcopy(result)
local limited_result, result_bytes = projection.limited_result(result, 8)
assert(vim.deep_equal(result, authoritative_result), "result projection mutated the authoritative result")
assert(result_bytes <= 8, "result projection exceeded its byte limit")
assert(limited_result.details.clientTruncated, "result truncation metadata is missing")
local detail_summary = projection.details_without_output(result.details)
assert(
  detail_summary.output == nil and detail_summary.fullOutputPath == "/tmp/full.log",
  "Bash details retained output"
)

local assistant = {
  role = "assistant",
  content = {
    { type = "thinking", thinking = "reasoning" },
    { type = "text", text = string.rep("answer", 8) },
  },
  stopReason = "stop",
}
local authoritative_assistant = vim.deepcopy(assistant)
local bounded, assistant_bytes, assistant_omitted, had_thinking = projection.bounded_assistant(assistant, 24, {})
assert(vim.deep_equal(assistant, authoritative_assistant), "assistant projection mutated the authoritative message")
assert(bounded ~= assistant and assistant_bytes <= 24 and assistant_omitted > 0, "assistant message was not bounded")
assert(had_thinking, "thinking presence was lost during projection")

print("transcript_projection_spec: ok")
