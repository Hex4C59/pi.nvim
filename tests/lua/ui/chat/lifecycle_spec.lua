local config = require("pi.config")
local image_data = require("pi.ui.image")
local Backend = require("pi.ui.image.backend").Backend
local Chat = require("pi.ui.chat").Chat
local registry = require("pi.ui.chat.registry").default()

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
local chats = {}

local function track(chat)
  table.insert(chats, chat)
  return chat
end

local function buffer_text(chat)
  return table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view:buffer(), 0, -1, false), "\n")
end

local function styled_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

local function input_footer(chat)
  return styled_text(vim.api.nvim_win_get_config(chat.input_area:window()).footer)
end

local function mapping_count(buf, mode)
  return #vim.api.nvim_buf_get_keymap(buf, mode)
end

local function complete_assistant(chat, content, stop_reason)
  local message = { role = "assistant", content = content, stopReason = stop_reason or "stop" }
  chat:start_assistant(message)
  chat:end_assistant(message)
end

config.setup({
  security = { mode = "confirm" },
  chat = { position = "right", width = 0.6 },
  images = { backend = "text", max_width = 32, max_height = 16 },
})

local function run()
  local root = vim.fs.joinpath(vim.fn.getcwd(), "lifecycle-project")
  local backend_clears = 0
  local chat = track(Chat.new(root))
  chat.image_backend = Backend.new({
    requested = "text",
    adapter = {
      clear = function()
        backend_clears = backend_clears + 1
      end,
    },
  })
  chat:open(false)

  local frame_calls = 0
  local layout_calls = 0
  local original_update_frame = chat.input_area.update_frame
  local original_layout = chat.shell.layout
  chat.input_area.update_frame = function(area)
    frame_calls = frame_calls + 1
    return original_update_frame(area)
  end
  chat.shell.layout = function(shell)
    layout_calls = layout_calls + 1
    return original_layout(shell)
  end

  chat:set_activity("working")
  local activity_timer = assert(chat.animation_timer, "working did not start the Chat activity timer")
  local layout_after_start = layout_calls
  local frame_before = chat.animation_frame
  assert(
    vim.wait(500, function()
      return chat.animation_frame ~= frame_before
    end, 20),
    "working animation frame did not advance"
  )
  assert(frame_calls > 0, "activity animation did not update InputArea chrome")
  assert(layout_calls == layout_after_start, "activity animation triggered full Chat layout")
  chat:set_activity("working")
  assert(chat.animation_timer == activity_timer, "repeated working state created a duplicate timer")

  chat:start_assistant({ role = "assistant", content = {} })
  chat:update_assistant({ role = "assistant", content = {} }, { type = "thinking_start", contentIndex = 0 })
  assert(input_footer(chat):find("Thinking ·", 1, true), "thinking start did not show the generic activity stage")
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Assessing" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = "**Assessing",
  })
  assert(not input_footer(chat):find("Assessing", 1, true), "partial reasoning header replaced the generic stage")
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Assessing cohesion**" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = " cohesion**",
  })
  assert(input_footer(chat):find("Assessing cohesion", 1, true), "complete reasoning header did not become the stage")
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Assessing cohesion**\n\n**Implementing" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = "\n\n",
  })
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Assessing cohesion**\n\n**Implementing" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = "**Implementing",
  })
  assert(input_footer(chat):find("Assessing cohesion", 1, true), "partial next header replaced the current stage")
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Assessing cohesion**\n\n**Implementing changes**" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = " changes**",
  })
  assert(
    input_footer(chat):find("Implementing changes", 1, true),
    "next complete reasoning header did not replace the stage"
  )
  assert(
    not buffer_text(chat):find("Implementing changes", 1, true),
    "transient reasoning stage leaked into hidden transcript"
  )

  local live_message = {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "**Implementing changes**" },
      { type = "text", text = "Lifecycle public answer" },
    },
  }
  chat:update_assistant(live_message, { type = "text_delta", contentIndex = 1, delta = "Lifecycle public answer" })
  assert(not input_footer(chat):find("Implementing changes", 1, true), "public text did not clear the reasoning stage")
  chat:end_assistant(vim.tbl_extend("force", {}, live_message, { stopReason = "stop" }))
  assert(chat.transcript.reasoning_header == nil, "assistant end retained transient reasoning state")

  chat:start_assistant({ role = "assistant", content = {} })
  chat:update_assistant({
    role = "assistant",
    content = { { type = "thinking", thinking = "**Abort stage**" } },
  }, {
    type = "thinking_delta",
    contentIndex = 0,
    delta = "**Abort stage**",
  })
  chat:end_assistant({ role = "assistant", content = {}, stopReason = "aborted" })
  assert(chat.transcript.reasoning_header == nil, "aborted assistant retained transient reasoning state")
  chat:set_activity("idle")
  assert(chat.animation_timer == nil, "idle did not stop the activity timer")
  chat:set_activity("error")
  assert(chat.animation_timer == nil, "error state retained an activity timer")

  chat.input_area.update_frame = original_update_frame
  chat.shell.layout = original_layout
  chat:update_state({ model = { id = "lifecycle-model" }, thinkingLevel = "medium" })
  chat:add_user("preserved close state")
  complete_assistant(chat, { { type = "text", text = "preserved answer" } })
  chat:start_tool("close-tool", "read", { path = "README.md" })
  chat:end_tool("close-tool", { content = { { type = "text", text = "close result" } } }, false)
  chat:set_activity("idle")
  assert(chat:set_widget("lifecycle.widget", { "Lifecycle widget" }, "aboveEditor"), "lifecycle widget was rejected")
  local widget_buffer = assert(chat.widget_area:buffer("aboveEditor"), "widget buffer was not created")

  chat:_focus_input()
  chat:set_input("/mo")
  assert(chat:_update_command_menu(), "lifecycle command menu did not open")
  local command_buffer = chat.command_menu:buffer()
  local command_window = chat.command_menu:window()

  local image = { type = "image", mimeType = "image/png", data = png_base64 }
  assert(image_data.prepare(image, 20), "preview lifecycle image was not prepared")
  assert(chat:_open_image_preview({ block = image }), "Chat image preview did not open")
  local preview_buffer = chat.image_preview.buf
  local preview_window = chat.image_preview.win

  local decisions = {}
  chat:confirm({ id = "close-permission", method = "confirm", title = "Confirm", message = "fixture" }, function(value)
    table.insert(decisions, value)
  end)
  assert(chat:has_active_permission_request(), "permission request was not active before close")
  assert(not vim.api.nvim_win_is_valid(command_window), "permission request did not close the command menu")

  local transcript_buffer = chat.transcript_view:buffer()
  local input_buffer = chat.input_area:buffer()
  local status_buffer = chat.input_area:status_buffer()
  local main_window = chat.win
  local input_window = chat.input_area:window()
  local status_window = chat.input_area:status_window()
  local item_count = #chat.transcript.items
  local normal_maps = mapping_count(input_buffer, "n")
  local generation_before_close = chat:action_generation()
  chat:set_activity("working")
  assert(chat.animation_timer, "close fixture did not restart activity")
  chat:close()

  assert(not chat:is_open(), "close left the complete Chat shell open")
  assert(chat:action_generation() == generation_before_close + 1, "close did not invalidate async menu callbacks")
  assert(chat.animation_timer == nil, "close retained the activity timer")
  assert(decisions[1] == false and not chat:has_active_permission_request(), "close did not fail closed")
  for _, win in ipairs({ main_window, input_window, status_window, preview_window }) do
    assert(not vim.api.nvim_win_is_valid(win), "close leaked a component window")
  end
  assert(not vim.api.nvim_buf_is_valid(preview_buffer), "close leaked the image preview buffer")
  for _, buf in ipairs({ transcript_buffer, input_buffer, status_buffer, command_buffer, widget_buffer }) do
    assert(vim.api.nvim_buf_is_valid(buf), "close deleted reusable component state")
  end
  assert(
    #chat.transcript.items == item_count and chat.model == "lifecycle-model",
    "close changed session display state"
  )

  chat:open(false)
  assert(chat:is_open(), "Chat did not reopen after close")
  assert(chat.transcript_view:buffer() == transcript_buffer, "reopen replaced the transcript buffer")
  assert(
    chat.input_area:buffer() == input_buffer and chat.input_area:status_buffer() == status_buffer,
    "reopen replaced input buffers"
  )
  assert(mapping_count(input_buffer, "n") == normal_maps, "reopen duplicated prompt mappings")

  chat:update_permission_mode("manual")
  chat:add_image_attachment(image)
  chat:set_widget("lifecycle.widget", { "Stale widget" }, "aboveEditor")
  assert(chat:retained_transcript_bytes() > 0, "clear fixture did not retain transcript bytes")
  chat:clear()
  assert(#chat.transcript.items == 0 and next(chat.transcript.tools_by_id) == nil, "clear retained transcript indexes")
  assert(
    chat.transcript.non_tool_retained_bytes == 0 and chat.transcript.tool_retained_bytes == 0,
    "clear retained transcript body bytes"
  )
  assert(
    #chat.transcript_view.tool_ranges == 0 and #chat.transcript_view.process_ranges == 0,
    "clear retained hit ranges"
  )
  assert(
    chat:retained_transcript_bytes() == chat.transcript_view:projection_bytes()
      and chat:retained_transcript_bytes() < config.get().output.transcript_max_bytes,
    "clear did not replace stale projection accounting with a bounded welcome"
  )
  assert(
    next(chat.widget_area.widgets) == nil and #chat.pending_attachments == 0,
    "clear retained widget or attachment state"
  )
  assert(
    chat.transcript.reasoning_header == nil and chat.transcript.reasoning_buffer == "",
    "clear retained reasoning state"
  )
  assert(chat:permission_mode() == nil, "clear did not reset the permission display mirror")
  assert(buffer_text(chat):find("coding agent", 1, true), "clear did not restore the welcome")

  chat:add_user("after clear")
  complete_assistant(chat, { { type = "text", text = "after clear answer" } })
  chat:start_tool("after-clear-tool", "read", { path = "lua/pi/init.lua" })
  chat:end_tool("after-clear-tool", { content = { { type = "text", text = "after clear result" } } }, false)
  assert(buffer_text(chat):find("after clear answer", 1, true), "events did not render after clear")

  chat:render_history({ { role = "assistant", content = { { type = "text", text = "first history" } } } })
  assert(chat:retained_transcript_bytes() > 0, "history did not populate the local projection")
  chat:update_stats({ tokens = { input = 10 }, contextUsage = { percent = 20 }, cost = 1 })
  local reset_menu = chat:open_inline_menu({ kind = "select", title = "Reset menu", items = { "one" } })
  local generation_before_reset = chat:action_generation()
  chat:reset_session_projection()
  assert(chat:action_generation() == generation_before_reset + 1, "session reset did not invalidate menu callbacks")
  assert(reset_menu.closed and not chat:inline_menu_active(), "session reset retained an inline menu")
  assert(chat:retained_transcript_bytes() == 0 and not chat.transcript.history_loaded, "session reset retained history")
  assert(next(chat.stats.tokens) == nil and chat.stats.cost == 0, "session reset retained statistics")
  chat:render_history({ { role = "assistant", content = { { type = "text", text = "replacement history" } } } })
  assert(buffer_text(chat):find("replacement history", 1, true), "session reset did not permit history reload")

  chat:set_widget("destroy.widget", { "Destroy widget" }, "aboveEditor")
  local destroy_widget_buffer =
    assert(chat.widget_area:buffer("aboveEditor"), "destroy fixture widget buffer was not created")
  chat:_focus_input()
  chat:set_input("/mo")
  assert(chat:_update_command_menu(), "destroy fixture command menu did not open")
  local destroy_command_buffer = chat.command_menu:buffer()
  local destroy_command_window = chat.command_menu:window()
  assert(chat:_open_image_preview({ block = image }), "destroy fixture image preview did not open")
  local destroy_preview_buffer = chat.image_preview.buf
  local destroy_preview_window = chat.image_preview.win
  local destroy_inline_surface = chat:open_inline_menu({
    kind = "select",
    title = "Destroy menu",
    items = { "one", "two" },
  })
  local destroy_inline_buffer = chat.inline_menu:buffer()
  local destroy_inline_window = chat.inline_menu:window()
  chat:start_assistant({ role = "assistant", content = {} })
  chat:update_assistant({ role = "assistant", content = { { type = "text", text = "pending render" } } }, {
    type = "text_delta",
    contentIndex = 0,
    delta = "pending render",
  })
  assert(chat.transcript_view.render_pending and chat.transcript_view.render_timer, "stream did not schedule a render")
  chat:set_activity("working")
  local delayed_callback = false
  vim.schedule(function()
    delayed_callback = true
    chat:_sync_animation()
  end)

  local destroy_windows = {
    chat.win,
    chat.input_area:window(),
    chat.input_area:status_window(),
    destroy_command_window,
    destroy_preview_window,
    destroy_inline_window,
  }
  local destroy_buffers = {
    chat.transcript_view:buffer(),
    chat.input_area:buffer(),
    chat.input_area:status_buffer(),
    destroy_command_buffer,
    destroy_widget_buffer,
    destroy_preview_buffer,
    destroy_inline_buffer,
  }
  chat:destroy()
  chat:destroy()
  assert(chat.destroyed and chat.animation_timer == nil, "destroy did not become idempotently terminal")
  assert(destroy_inline_surface.closed, "destroy did not invalidate the inline menu callback surface")
  assert(
    chat.transcript_view.render_timer == nil and not chat.transcript_view.render_pending,
    "destroy retained render work"
  )
  assert(registry.instances[root] == nil, "destroy retained the Chat registry entry")
  for _, win in ipairs(destroy_windows) do
    assert(not win or not vim.api.nvim_win_is_valid(win), "destroy leaked a component window")
  end
  for _, buf in ipairs(destroy_buffers) do
    assert(not buf or not vim.api.nvim_buf_is_valid(buf), "destroy leaked an owned buffer")
  end
  assert(backend_clears > 0, "destroy never released image backend resources")
  assert(
    vim.wait(200, function()
      return delayed_callback
    end, 10),
    "scheduled post-destroy callback did not run"
  )
  assert(chat.animation_timer == nil, "post-destroy callback restarted activity")

  local damaged_root = vim.fs.joinpath(vim.fn.getcwd(), "lifecycle-damaged-project")
  local damaged = track(Chat.new(damaged_root))
  damaged.image_backend = Backend.new({
    requested = "text",
    adapter = {
      clear = function()
        error("cleanup fixture failure")
      end,
    },
  })
  damaged:open(false)
  damaged:set_widget("damaged.widget", { "Damaged widget" }, "aboveEditor")
  local damaged_widget_buffer = damaged.widget_area:buffer("aboveEditor")
  damaged:start_assistant({ role = "assistant", content = {} })
  damaged:update_assistant({ role = "assistant", content = { { type = "text", text = "pending" } } }, {
    type = "text_delta",
    contentIndex = 0,
    delta = "pending",
  })
  local damaged_decision
  damaged:confirm(
    { id = "damaged-permission", method = "confirm", title = "Confirm", message = "fixture" },
    function(value)
      damaged_decision = value
    end
  )
  local damaged_main = damaged.win
  vim.api.nvim_win_close(damaged_main, true)
  assert(not damaged:is_open(), "externally closed main window remained open")
  damaged:destroy()
  assert(damaged_decision == false, "out-of-order destroy did not fail closed")
  assert(not vim.api.nvim_buf_is_valid(damaged_widget_buffer), "out-of-order destroy leaked widget state")
  assert(damaged.transcript_view.render_timer == nil, "out-of-order destroy retained scheduled render")

  local partial = track(Chat.new(vim.fs.joinpath(vim.fn.getcwd(), "lifecycle-partial-project")))
  local partial_input = partial.input_area:ensure_input_buffer()
  local partial_status = partial.input_area:ensure_status_buffer()
  local partial_command = partial.command_menu:ensure_buffer()
  vim.api.nvim_buf_delete(partial_input, { force = true })
  vim.api.nvim_buf_delete(partial_status, { force = true })
  partial:destroy()
  partial:destroy()
  assert(not vim.api.nvim_buf_is_valid(partial_command), "partial destroy leaked CommandMenu state")
end

local ok, err = xpcall(run, debug.traceback)
for index = #chats, 1, -1 do
  pcall(chats[index].destroy, chats[index])
end
if not ok then
  error(err)
end
print("chat_lifecycle_spec: ok")
