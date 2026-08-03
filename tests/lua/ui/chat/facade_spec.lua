local Chat = require("pi.ui.chat").Chat

local root = vim.fs.joinpath(vim.fn.getcwd(), "facade-project")
local submitted
local chat = Chat.new(root, {
  submit = function(prompt, behavior, images)
    submitted = { prompt = prompt, behavior = behavior, images = images }
  end,
})

chat:open(true)
assert(chat:project_root() == root, "Chat facade lost its immutable project identity")
assert(vim.api.nvim_get_current_win() == chat.input_area:window(), "Chat facade did not focus the prompt")
for _, component in ipairs({
  chat.command_menu,
  chat.input_area,
  chat.permission_area,
  chat.widget_area,
  chat.image_backend,
  chat.transcript,
  chat.transcript_view,
  chat.image_preview,
}) do
  assert(type(component) == "table", "Chat facade did not attach a primary component")
end

chat:set_input("first line\nsecond line")
vim.cmd("stopinsert")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
assert(
  vim.wait(1000, function()
    return submitted ~= nil
  end, 10),
  "Chat facade did not submit through InputArea"
)
assert(submitted.prompt == "first line\nsecond line", "Chat facade changed the multiline prompt")
assert(#submitted.images == 0, "Chat facade invented prompt attachments")
chat:add_user(submitted.prompt)

local assistant = {
  role = "assistant",
  content = {
    { type = "thinking", thinking = "private facade reasoning" },
    { type = "text", text = "Facade public answer" },
  },
  stopReason = "stop",
}
chat:start_assistant(assistant)
chat:end_assistant(assistant)
chat:set_activity("working")
chat:start_tool("facade-tool", "read", { path = "README.md" })
chat:update_tool("facade-tool", { content = { { type = "text", text = "partial facade result" } } })
chat:end_tool("facade-tool", { content = { { type = "text", text = "final facade result" } } }, false)
chat:set_activity("idle")
chat:update_state({ model = { id = "facade-model" }, thinkingLevel = "medium", autoCompactionEnabled = true })
chat:update_permission_mode("manual")
chat:set_queue({ steering = { "correction" }, followUp = { "next" } })
chat:update_stats({ tokens = { input = 100 }, contextUsage = { percent = 25 }, cost = 0.1 })

local transcript = table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view:buffer(), 0, -1, false), "\n")
assert(transcript:find("first line", 1, true), "Chat facade did not compose the user prompt")
assert(transcript:find("Facade public answer", 1, true), "Chat facade did not compose the assistant answer")
assert(transcript:find("read 1 file", 1, true), "Chat facade did not settle the tool into a process summary")
assert(not transcript:find("private facade reasoning", 1, true), "Chat facade leaked private reasoning")
assert(transcript:find("facade-model · medium", 1, true), "model display mirror did not reach the welcome")
local status = table.concat(vim.api.nvim_buf_get_lines(chat.input_area:status_buffer(), 0, -1, false), "\n")
assert(status:find("Manual", 1, true), "permission display mirror did not reach InputArea")
assert(status:find("steer 1", 1, true) and status:find("next 1", 1, true), "queue mirror did not reach InputArea")
local display_state = chat:display_state()
assert(
  display_state.layout == chat:current_layout()
    and display_state.permission_mode == "manual"
    and display_state.permission_mode_label == "Manual",
  "Chat facade display snapshot lost projected state"
)
display_state.permission_mode = "mutated"
assert(chat:permission_mode() == "manual", "mutating a display snapshot changed Chat state")
for _, buf in ipairs({
  chat.transcript_view:buffer(),
  chat.input_area:buffer(),
  chat.input_area:status_buffer(),
}) do
  assert(chat:owns_buffer(buf), "Chat facade did not expose component-owned buffers")
end

local reusable_transcript = chat.transcript_view:buffer()
chat:close()
assert(
  not chat:is_open() and vim.api.nvim_buf_is_valid(reusable_transcript),
  "Chat facade close destroyed reusable state"
)
chat:destroy()
assert(not vim.api.nvim_buf_is_valid(reusable_transcript), "Chat facade destroy leaked transcript state")

print("chat_facade_spec: ok")
