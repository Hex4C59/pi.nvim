local Chat = require("pi.ui.chat").Chat

local function styled_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

local chat = Chat.new(vim.fs.joinpath(vim.fn.getcwd(), "activity-project"))
chat:open(false)

local frame_before = chat.animation_frame
chat:set_activity("working")
assert(
  vim.wait(500, function()
    return chat.animation_frame ~= frame_before
  end, 20),
  "working frame animation did not advance"
)

chat:start_assistant({ role = "assistant", content = {} })
chat:update_assistant({ role = "assistant", content = {} }, { type = "thinking_start", contentIndex = 0 })
chat:update_assistant({
  role = "assistant",
  content = { { type = "thinking", thinking = "**Assessing cohesion of Lua modules**" } },
}, {
  type = "thinking_delta",
  contentIndex = 0,
  delta = "**Assessing cohesion of Lua modules**",
})
local input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
assert(
  input_footer:find("Assessing cohesion of Lua modules", 1, true),
  "reasoning header did not replace the generic activity label"
)
assert(not input_footer:find("Thinking ·", 1, true), "reasoning header was appended to the current stage")

local live_message = {
  role = "assistant",
  content = {
    { type = "thinking", thinking = "**Assessing cohesion of Lua modules**" },
    { type = "text", text = "Live public update" },
  },
}
chat:update_assistant(live_message, { type = "text_delta", contentIndex = 1, delta = "Live public update" })
input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
assert(not input_footer:find("Assessing cohesion", 1, true), "reasoning header remained after public output started")
chat:end_assistant(vim.tbl_extend("force", {}, live_message, { stopReason = "stop" }))

chat:set_activity("idle")
assert(chat.animation_timer == nil, "working animation did not stop")

chat:set_activity("error")
assert(chat.animation_timer == nil, "error state must not keep the frame animation alive")

chat:set_queue({ steering = { "one" }, followUp = { "two" } })
local status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(status:find("steer 1", 1, true), "steering queue is missing")
assert(status:find("next 1", 1, true), "follow-up queue is missing")

chat:destroy()
print("chat_activity_spec: ok")
