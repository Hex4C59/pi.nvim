local config = require("pi.config")
local pi = require("pi")

local lua_parser_available = pcall(function()
  local parser = vim.treesitter.get_string_parser("local value = true", "lua")
  assert(parser:parse()[1])
  assert(vim.treesitter.query.get("lua", "highlights"))
end)

local root = vim.fn.getcwd()
config.setup({
  command = root .. "/tests/fake_pi.js",
  persist_session = false,
  project_trust = "never",
  security = { mode = "full" },
  request_timeout = 3000,
})

pi.chat()

local function find_buffer(kind)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[bufnr].pi_kind == kind then
      return bufnr
    end
  end
end

local chat_buf = assert(find_buffer("chat"), "chat buffer was not created")
local input_buf = assert(find_buffer("prompt"), "prompt buffer was not created")
assert(
  vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    return text:find("history answer", 1, true) ~= nil
  end, 20),
  "history was not rendered"
)

assert(
  vim.wait(3000, function()
    return #require("pi.ui.chat").complete(0, "/fixture-noop") == 1
  end, 20),
  "extension command catalog was not loaded"
)

pi.submit("/fixture-prefill", root)
assert(
  vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "extension draft"
  end, 20),
  "set_editor_text did not prefill the Pi prompt"
)
pi.submit("/fixture-clear", root)
assert(
  vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == ""
  end, 20),
  "set_editor_text did not clear the Pi prompt"
)

pi.submit("/fixture-noop", root)
pi.submit("hello from fixture", root)
local status_buf = assert(find_buffer("status"), "status buffer was not created")
local settled = vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  local status = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
  return text:find("live answer", 1, true) ~= nil
    and text:find("▸ Thought", 1, true) ~= nil
    and text:find("read 1 file", 1, true) ~= nil
    and status:find("fixture · high", 1, true) ~= nil
end, 20)
if not settled then
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  local status = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
  error("live RPC events did not settle\ntranscript:\n" .. text .. "\nstatus:\n" .. status)
end

local transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(transcript:find("hello from fixture", 1, true), "live user message is missing")
assert(not transcript:find("/fixture-noop", 1, true), "extension command leaked into the next user message")
assert(not transcript:find("extension draft", 1, true), "set_editor_text submitted an unrequested model prompt")
local rpc_answer = assert(transcript:find("live answer", 1, true), "live RPC answer is missing")
local rpc_summary = assert(transcript:find("▸ Thought", 1, true), "settled RPC task did not collapse its process")
assert(rpc_answer < rpc_summary, "settled RPC process summary must appear below the public answer")
assert(not transcript:find("live reasoning", 1, true), "settled RPC task leaked thinking details")
assert(not transcript:find("fixture.txt", 1, true), "settled RPC task leaked its file read")
assert(transcript:find(" Analysis", 1, true), "Markdown heading is missing")
assert(not transcript:find("# Analysis", 1, true), "Markdown heading marker leaked into the canvas")
assert(transcript:find(" │ structured response", 1, true), "Markdown quote is missing")
assert(transcript:find("local ready = true", 1, true), "Markdown code block is missing")
local syntax_highlight = false
local ui_namespace = assert(vim.api.nvim_get_namespaces()["pi.nvim"], "Pi UI namespace is missing")
for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, ui_namespace, 0, -1, { details = true })) do
  syntax_highlight = syntax_highlight or extmark[4].hl_group == "@keyword.lua"
end
if lua_parser_available then
  assert(syntax_highlight, "Tree-sitter syntax highlight did not reach the chat buffer")
end
assert(not transcript:find("Edited  example.lua", 1, true), "settled RPC task leaked its edit tool")
assert(not transcript:find("- local old = true", 1, true), "settled RPC task leaked its diff")
assert(not transcript:find("final output", 1, true), "collapsed read leaked its output")
local completions = require("pi.ui.chat").complete(0, "/fix")
assert(#completions >= 1 and completions[1].word:find("/fixture", 1, true), "dynamic commands were not loaded")

pi.submit("/fixture-template concise", root)
assert(
  vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    return text:find("/fixture-template concise", 1, true) ~= nil
  end, 20),
  "prompt template lost its concise display text"
)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(
  not transcript:find("expanded template payload", 1, true),
  "expanded template content leaked into the transcript"
)

pi.submit("first accepted", root)
pi.submit("second rejected", root)
assert(
  vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    return text:find("first accepted", 1, true) ~= nil
  end, 20),
  "an accepted prompt was removed by another request's failure"
)
transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not transcript:find("second rejected", 1, true), "a rejected prompt replaced the accepted prompt display")

local status = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
assert(status:find("fixture · high", 1, true), "model state is missing from the footer")
assert(status:find("fixture · high", 1, true) == 3, "model state is not aligned with the composer")
assert(not status:find("idle", 1, true), "idle state should be hidden")

local notification = nil
local original_notify = vim.notify
vim.notify = function(message)
  notification = message
end
pi.status(root)
assert(
  vim.wait(3000, function()
    return notification ~= nil
  end, 20),
  "session statistics notification was not shown"
)
vim.notify = original_notify
assert(notification:find("Input tokens: 10", 1, true), "session details are missing input tokens")
assert(notification:find("Output tokens: 5", 1, true), "session details are missing output tokens")
assert(notification:find("Cache read: 20 (66.7% hit)", 1, true), "session details are missing cache usage")
assert(notification:find("Cost: $0.0010", 1, true), "session details are missing cost")
assert(notification:find("Auto-compact: on", 1, true), "session details are missing compaction state")

pi.submit("/clear", root)
assert(
  vim.wait(3000, function()
    local cleared_transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    local cleared_status = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), "\n")
    return not cleared_transcript:find("history question", 1, true)
      and not cleared_transcript:find("hello from fixture", 1, true)
      and cleared_status:find("context 0%", 1, true) ~= nil
  end, 20),
  "/clear did not reset the Pi session transcript and context usage"
)

pi.stop_all()

print("rpc_ui_spec: ok")
