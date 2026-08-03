local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local root = vim.fs.joinpath(vim.fn.getcwd(), "facade-project")
local chat = Chat.new(root)

assert(chat:project_root() == root, "Chat did not expose its immutable project identity")
chat:set_path(vim.fs.joinpath(root, "nested.lua"))
assert(chat:project_root() == root, "changing display context mutated the Chat project identity")

assert(chat:current_layout() == config.get().chat.position, "Chat did not expose the configured layout default")
assert(not chat:process_details_enabled(), "Chat started with detailed process rendering enabled")

chat:set_position("bottom")
chat:toggle_process()
chat:update_permission_mode("auto")
local state = chat:display_state()
assert(state.layout == "bottom", "display-state snapshot lost the current layout")
assert(state.process_expanded == true, "display-state snapshot lost process detail state")
assert(state.permission_mode == "auto", "display-state snapshot lost the authoritative permission mirror")
assert(state.permission_mode_label == "Auto", "display-state snapshot lost the permission label")
state.layout = "mutated"
state.process_expanded = false
assert(chat:current_layout() == "bottom", "mutating a display-state snapshot changed the Chat layout")
assert(chat:process_details_enabled(), "mutating a display-state snapshot changed Chat detail state")

chat:render_history({
  { role = "assistant", content = { { type = "text", text = "first history" } } },
})
assert(chat:retained_transcript_bytes() > 0, "history fixture did not populate the local projection")
chat:reset_session_projection()
assert(chat:retained_transcript_bytes() == 0, "session projection reset retained transcript content")
chat:render_history({
  { role = "assistant", content = { { type = "text", text = "replacement history" } } },
})
assert(chat:retained_transcript_bytes() > 0, "session projection reset did not permit history to reload")

assert(not chat:has_active_permission_request(), "Chat reported a permission request before one was shown")
chat:select_permission({
  id = "facade-permission",
  method = "select",
  title = "Permission",
  message = "fixture",
  options = { "Block", "Allow once" },
}, function() end)
assert(chat:has_active_permission_request(), "Chat facade hid the active permission request")
chat.permission_area:_resolve("Block")
assert(not chat:has_active_permission_request(), "Chat facade retained a resolved permission request")

chat:destroy()
print("chat_facade_spec: ok")
