local Chat = require("pi.ui.chat").Chat

local function styled_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

local function has_highlight(chunks, highlight)
  for _, chunk in ipairs(chunks or {}) do
    if chunk[2] == highlight then
      return true
    end
  end
  return false
end

local function assert_input_border(config, edge_highlight, corner_highlight, message)
  for index, segment in ipairs(config.border) do
    local expected = index % 2 == 1 and corner_highlight or edge_highlight
    assert(segment[2] == expected, message)
  end
end

local chat = Chat.new(vim.fs.joinpath(vim.fn.getcwd(), "activity-project"))
chat:open(false)

local frame_before = chat.animation_frame
chat:set_activity("working")
local initial_active_title = vim.inspect(vim.api.nvim_win_get_config(chat.input_area:window()).title)
assert(
  vim.wait(500, function()
    return chat.animation_frame ~= frame_before
  end, 20),
  "working frame animation did not advance"
)
local input_config = vim.api.nvim_win_get_config(chat.input_area:window())
local input_title = styled_text(input_config.title)
local input_footer = styled_text(input_config.footer)
assert(vim.inspect(input_config.title) ~= initial_active_title, "working highlight did not move across the frame")
assert(has_highlight(input_config.title, "PiInputBorderPulse"), "working frame is missing its moving highlight")
assert(input_footer:find("Thinking ·", 1, true), "working state is missing from the input frame")
assert(not input_title:find("Thinking", 1, true), "activity label must appear only on the bottom border")
assert(vim.api.nvim_strwidth(input_title) == input_config.width, "animated top border changed width")
assert(vim.api.nvim_strwidth(input_footer) == input_config.width, "animated bottom border changed width")

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
input_footer = styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
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
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
assert(not styled_text(input_config.footer):find("Thinking", 1, true), "idle frame retained the activity label")
assert_input_border(input_config, "PiInputBorder", "PiInputCorner", "idle frame did not restore its normal border")

chat:set_activity("error")
input_config = vim.api.nvim_win_get_config(chat.input_area:window())
assert(styled_text(input_config.footer):find("Error", 1, true), "error label is missing from the input frame")
assert_input_border(
  input_config,
  "PiInputBorderError",
  "PiInputCornerError",
  "error frame did not switch to its semantic color"
)
assert(chat.animation_timer == nil, "error state must not keep the frame animation alive")

chat:set_queue({ steering = { "one" }, followUp = { "two" } })
local status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(status:find("steer 1", 1, true), "steering queue is missing")
assert(status:find("next 1", 1, true), "follow-up queue is missing")

chat:destroy()
print("chat_activity_spec: ok")
