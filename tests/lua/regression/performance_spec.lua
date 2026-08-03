local config = require("pi.config")
local renderer = require("pi.ui.render")
local Chat = require("pi.ui.chat").Chat

config.setup({
  chat = { position = "right" },
  persist_session = false,
})

local chat = Chat.new(vim.fn.getcwd() .. "/performance")
chat:open(false)
chat:set_activity("idle")
chat:add_user("first question")
chat:start_assistant({ content = { { type = "text", text = "first answer" } } })
chat:end_assistant({ content = { { type = "text", text = "first answer" } }, stopReason = "stop" })
chat:set_activity("idle")
chat:add_user("second question")
chat:set_activity("working")
chat:start_assistant({ content = { { type = "text", text = "partial answer" } } })

local prefix_extmarks = vim.api.nvim_buf_get_extmarks(chat.buf, -1, { 0, 0 }, { 0, -1 }, {})
assert(#prefix_extmarks > 0, "performance fixture is missing stable prefix extmarks")

local original_render = renderer.render
local original_set_lines = vim.api.nvim_buf_set_lines
local rendered_item_counts = {}
local transcript_writes = {}
renderer.render = function(items, opts)
  table.insert(rendered_item_counts, #items)
  return original_render(items, opts)
end
vim.api.nvim_buf_set_lines = function(buf, first, last, strict, lines)
  if buf == chat.buf then
    table.insert(transcript_writes, { first = first, last = last, count = #lines })
  end
  return original_set_lines(buf, first, last, strict, lines)
end

local ok, err = pcall(function()
  chat.streaming_assistant.message = {
    content = { { type = "text", text = "partial answer with another streamed chunk" } },
  }
  chat:_render_transcript()
end)
renderer.render = original_render
vim.api.nvim_buf_set_lines = original_set_lines
assert(ok, err)

assert(
  vim.deep_equal(rendered_item_counts, { 2 }),
  "streaming render traversed completed transcript items instead of only the active turn"
)
assert(#transcript_writes == 1, "streaming update did not coalesce to one transcript buffer write")
assert(
  transcript_writes[1].first > 0 and transcript_writes[1].last ~= -1,
  "streaming update replaced the entire transcript buffer"
)
assert(
  transcript_writes[1].count < vim.api.nvim_buf_line_count(chat.buf),
  "streaming update copied the complete transcript into its write payload"
)
assert(chat.render_frame.lines == nil, "streaming frame retained a duplicate of every transcript line")
assert(
  #chat.render_frame.dynamic_lines < vim.api.nvim_buf_line_count(chat.buf),
  "streaming frame did not isolate the active tail"
)

local updated_prefix_extmarks = vim.api.nvim_buf_get_extmarks(chat.buf, -1, { 0, 0 }, { 0, -1 }, {})
assert(prefix_extmarks[1][1] == updated_prefix_extmarks[1][1], "unchanged prefix extmarks were deleted and recreated")

local width = vim.api.nvim_win_get_width(chat.win)
local expected = original_render(chat.items, {
  hide_thinking = chat.hide_thinking,
  tools_expanded = chat.tools_expanded,
  collapse_processes = true,
  process_expanded = chat.process_expanded,
  process_active = true,
  image_terminal = chat.image_backend:is_terminal(),
  root = chat.root,
  width = width,
  welcome = {
    model = chat.model,
    thinking = chat.thinking,
    root = chat.root,
    permission = chat:permission_mode() or "syncing",
    security = (config.get().security or {}).mode,
  },
})
for _ = 1, chat.overlay_height or 0 do
  table.insert(expected, "")
end
assert(
  vim.deep_equal(expected, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)),
  "cached transcript composition diverged from a full render"
)

local original_layout = chat._layout
local layout_calls = 0
chat._layout = function(self)
  layout_calls = layout_calls + 1
  return original_layout(self)
end
chat:set_activity("idle")
layout_calls = 0
local frame_before = chat.animation_frame
chat:set_activity("working")
local startup_layout_calls = layout_calls
assert(
  vim.wait(500, function()
    return chat.animation_frame ~= frame_before
  end, 20),
  "animation fixture did not advance"
)
assert(layout_calls == startup_layout_calls, "animation frame triggered a full workspace layout")
chat:set_activity("idle")
chat._layout = original_layout
chat:close()

print("performance_spec: ok")
