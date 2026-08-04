local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
local chats = {}
local scratch_buffers = {}

local function track_chat(chat)
  table.insert(chats, chat)
  return chat
end

local function buffer_text(chat)
  return table.concat(vim.api.nvim_buf_get_lines(chat.transcript_view:buffer(), 0, -1, false), "\n")
end

local function complete_assistant(chat, content)
  local message = { role = "assistant", content = content, stopReason = "stop" }
  chat:start_assistant(message)
  chat:end_assistant(message)
  return chat.transcript.items[#chat.transcript.items]
end

local function unhandled_row(view)
  local count = vim.api.nvim_buf_line_count(view:buffer())
  for row = 1, count do
    if not view:tool_at_row(row) and not view:process_at_row(row) and not view:image_at_row(row) then
      return row
    end
  end
end

config.setup({
  chat = { position = "right", width = 0.65 },
  images = { backend = "text", max_width = 32, max_height = 16 },
})

local function run()
  local copied = {}
  local notifications = {}
  local chat = track_chat(Chat.new(vim.fs.joinpath(vim.fn.getcwd(), "interactions-project"), {
    copy_to_clipboard = function(text)
      table.insert(copied, text)
      return true
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
  }))
  chat:open(false)
  chat:update_state({ model = { id = "fixture-model" }, thinkingLevel = "high", isStreaming = true })
  chat:add_user("interaction fixture")
  local assistant = complete_assistant(chat, {
    { type = "thinking", thinking = "private reasoning" },
    { type = "text", text = "public answer" },
  })
  local assistant_content = vim.deepcopy(assistant.message.content)

  chat:start_tool("interaction-tool", "bash", { command = "printf hello\nprintf world" })
  local output = {}
  for index = 1, 12 do
    table.insert(output, "line " .. index)
  end
  chat:end_tool("interaction-tool", { content = { { type = "text", text = table.concat(output, "\n") } } }, false)
  local tool = chat.transcript.tools_by_id["interaction-tool"]
  local transcript = buffer_text(chat)
  assert(transcript:find("line 1", 1, true) and transcript:find("line 12", 1, true), "collapsed tool lost its edges")
  assert(not transcript:find("line 6", 1, true), "collapsed tool exposed its middle output")

  local renders = 0
  local original_render = chat.transcript_view.render
  chat.transcript_view.render = function(view)
    renders = renders + 1
    return original_render(view)
  end
  chat:toggle_thinking()
  transcript = buffer_text(chat)
  assert(chat.process_expanded and not chat.hide_thinking, "thinking toggle did not expand local process display")
  assert(transcript:find("private reasoning", 1, true), "active thinking details did not become visible")
  assert(transcript:find("public answer", 1, true), "thinking toggle hid the public answer")
  assert(
    chat.thinking == "high" and chat.activity == "working",
    "thinking toggle changed authoritative display mirrors"
  )
  assert(
    vim.deep_equal(assistant.message.content, assistant_content),
    "thinking toggle mutated assistant message content"
  )
  chat:toggle_thinking()
  assert(not chat.process_expanded and chat.hide_thinking, "thinking toggle did not return to compact display")
  assert(renders == 2, "thinking toggles did not rerender TranscriptView exactly once each")
  chat.transcript_view.render = original_render

  chat:_focus_input()
  chat:toggle_tools()
  assert(
    chat.tools_expanded and buffer_text(chat):find("line 6", 1, true),
    "global tool expansion did not show full output"
  )
  chat:toggle_tools()
  assert(
    not chat.tools_expanded and not buffer_text(chat):find("line 6", 1, true),
    "global tool collapse retained middle output"
  )

  vim.api.nvim_set_current_win(chat.win)
  local tool_range = assert(chat.transcript_view.tool_ranges[1], "tool range is missing")
  vim.api.nvim_win_set_cursor(chat.win, { tool_range.first, 0 })
  chat:toggle_tools()
  assert(tool.expanded == true, "tool under cursor did not expand")
  assert(chat.tools_expanded == false, "per-tool expansion changed the global flag")
  assert(buffer_text(chat):find("line 6", 1, true), "per-tool expansion did not reveal middle output")

  tool_range = assert(chat.transcript_view.tool_ranges[1], "expanded tool range is missing")
  assert(
    chat:_handle_left_mouse({ winid = chat.win, line = tool_range.first, column = 1 }),
    "first tool-range row was not handled"
  )
  assert(tool.expanded == false, "first-row click did not collapse only the selected tool")
  tool_range = assert(chat.transcript_view.tool_ranges[1], "collapsed tool range is missing")
  assert(
    chat:_handle_left_mouse({ winid = chat.win, line = tool_range.last, column = 9999 }),
    "last tool-range row was not handled"
  )
  assert(tool.expanded == true, "last-row click did not expand the selected tool")
  assert(chat.tools_expanded == false, "tool mouse boundary changed global expansion")

  assert(
    not chat:_handle_left_mouse({ winid = chat.input_area:window(), line = 1, column = 1 }),
    "click in the prompt was consumed by transcript interaction"
  )
  local foreign_buffer = vim.api.nvim_create_buf(false, true)
  table.insert(scratch_buffers, foreign_buffer)
  local foreign_window = vim.api.nvim_open_win(foreign_buffer, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 10,
    height = 2,
    style = "minimal",
  })
  vim.api.nvim_win_close(foreign_window, true)
  assert(
    not chat:_handle_left_mouse({ winid = foreign_window, line = 1, column = 1 }),
    "deleted foreign window was consumed"
  )

  chat:set_activity("idle")
  transcript = buffer_text(chat)
  assert(transcript:find("ran 1 command", 1, true), "settled process summary is missing")
  assert(transcript:find("public answer", 1, true), "settlement hid public assistant output")
  assert(not transcript:find("private reasoning", 1, true), "compact settled process exposed private reasoning")
  assert(#chat.transcript_view.tool_ranges == 0, "settled process retained tool hit ranges")
  local process_range = assert(chat.transcript_view.process_ranges[1], "settled process range is missing")
  local settlement = chat.activity
  assert(
    chat:_handle_left_mouse({ winid = chat.win, line = process_range.first, column = 1 }),
    "compact process summary click was not handled"
  )
  transcript = buffer_text(chat)
  assert(chat.process_expanded and transcript:find("line 6", 1, true), "process click did not disclose details")
  assert(transcript:find("public answer", 1, true), "expanded process hid public assistant output")
  assert(chat.activity == settlement, "process disclosure changed settlement state")
  assert(vim.deep_equal(assistant.message.content, assistant_content), "process disclosure mutated assistant content")
  chat:toggle_process()
  assert(not chat.process_expanded, "keyboard process toggle did not restore compact state")
  local blank = assert(unhandled_row(chat.transcript_view), "fixture has no blank transcript row")
  assert(
    not chat:_handle_left_mouse({ winid = chat.win, line = blank, column = 1 }),
    "blank transcript row triggered a process action"
  )
  assert(not chat:_handle_left_mouse({
    winid = chat.win,
    line = vim.api.nvim_buf_line_count(chat.transcript_view:buffer()) + 100,
    column = 1,
  }), "stale out-of-bounds range was consumed")

  chat:clear()
  local plain = complete_assistant(chat, { { type = "text", text = "answer without thinking" } })
  local plain_content = vim.deepcopy(plain.message.content)
  chat:toggle_thinking()
  assert(
    chat.process_expanded and buffer_text(chat):find("answer without thinking", 1, true),
    "empty thinking toggle hid text"
  )
  assert(chat.thinking == "high", "empty thinking toggle changed the model thinking level")
  assert(vim.deep_equal(plain.message.content, plain_content), "empty thinking toggle mutated the message")
  chat:toggle_thinking()

  assert(chat:_copy_text("visible line one\nvisible line two"), "visible transcript text was not copied")
  assert(copied[#copied] == "visible line one\nvisible line two", "copy changed the visible transcript selection")
  assert(notifications[#notifications].level == vim.log.levels.INFO, "successful copy did not report completion")

  local transcript_before_failure = vim.deepcopy(chat.transcript.items)
  chat.copy_to_clipboard = function()
    error("clipboard offline")
  end
  assert(not chat:_copy_text("visible selection"), "clipboard adapter failure was reported as success")
  assert(
    notifications[#notifications].message:find("clipboard offline", 1, true)
      and notifications[#notifications].level == vim.log.levels.ERROR,
    "clipboard adapter failure was not reported"
  )
  assert(vim.deep_equal(chat.transcript.items, transcript_before_failure), "clipboard failure mutated transcript state")

  local notice_count = #notifications
  assert(not chat:_copy_text(""), "empty transcript selection produced clipboard content")
  assert(#notifications == notice_count, "empty transcript selection should remain a quiet no-op")

  chat:clear()
  chat:add_user("", {
    { type = "image", mimeType = "image/png", data = png_base64 },
  })
  assert(buffer_text(chat):find("Image", 1, true), "text backend did not render the deterministic image fallback")
  local image_block =
    assert(chat.transcript.items[#chat.transcript.items].content[1], "localized image block is missing")
  local descriptor = { row = 1, col = 0, width = 1, height = 1, range_height = 1, block = image_block }
  local second_descriptor = vim.tbl_extend("force", {}, descriptor, { key = "second-preview" })
  local unavailable_descriptor = vim.tbl_extend("force", {}, descriptor, { unavailable = true })
  local preview_open = chat.image_preview.open
  local preview_close = chat.image_preview.close
  local preview_calls = { opens = {}, closes = 0, replacements = 0, active = nil }
  chat.image_preview.open = function(_, selected)
    if selected.unavailable then
      return false
    end
    if preview_calls.active then
      preview_calls.replacements = preview_calls.replacements + 1
    end
    preview_calls.active = selected
    table.insert(preview_calls.opens, selected)
    return true
  end
  chat.image_preview.close = function()
    preview_calls.active = nil
    preview_calls.closes = preview_calls.closes + 1
  end

  local view = chat.transcript_view
  local original_tool_at_row = view.tool_at_row
  local original_process_at_row = view.process_at_row
  local original_image_at_mouse = view.image_at_mouse
  local mode = "tool"
  local lookup_calls = { tool = 0, process = 0, image = 0 }
  local structured_tool = { type = "tool", expanded = false }
  view.tool_at_row = function()
    lookup_calls.tool = lookup_calls.tool + 1
    return mode == "tool" and structured_tool or nil
  end
  view.process_at_row = function()
    lookup_calls.process = lookup_calls.process + 1
    return mode == "process" and { first = 1, last = 1 } or nil
  end
  view.image_at_mouse = function()
    lookup_calls.image = lookup_calls.image + 1
    if mode == "image" then
      return descriptor
    elseif mode == "unavailable" then
      return unavailable_descriptor
    end
  end

  assert(chat:_handle_left_mouse({ winid = chat.win, line = 1, column = 1 }), "structured tool click failed")
  assert(
    structured_tool.expanded and lookup_calls.process == 0 and lookup_calls.image == 0,
    "tool lost dispatch priority"
  )
  mode = "process"
  lookup_calls = { tool = 0, process = 0, image = 0 }
  assert(chat:_handle_left_mouse({ winid = chat.win, line = 1, column = 1 }), "structured process click failed")
  assert(
    lookup_calls.tool == 1 and lookup_calls.process == 1 and lookup_calls.image == 0,
    "process lost dispatch priority"
  )
  mode = "image"
  lookup_calls = { tool = 0, process = 0, image = 0 }
  assert(chat:_handle_left_mouse({ winid = chat.win, line = 1, column = 1 }), "structured image click failed")
  assert(
    lookup_calls.tool == 1 and lookup_calls.process == 1 and lookup_calls.image == 1 and #preview_calls.opens == 1,
    "image dispatch did not run exactly once after range misses"
  )
  assert(chat:_open_image_preview(second_descriptor), "second image did not reach ImagePreview")
  assert(
    preview_calls.replacements == 1 and #preview_calls.opens == 2,
    "ImagePreview did not receive replacement dispatch"
  )
  mode = "unavailable"
  local image_notice_count = #notifications
  assert(
    not chat:_handle_left_mouse({ winid = chat.win, line = 1, column = 1 }),
    "unavailable image preview was reported as opened"
  )
  assert(
    #notifications == image_notice_count + 1
      and notifications[#notifications].message:find("unavailable", 1, true)
      and notifications[#notifications].level == vim.log.levels.WARN,
    "unavailable image preview did not report its fallback"
  )
  mode = "blank"
  lookup_calls = { tool = 0, process = 0, image = 0 }
  assert(not chat:_handle_left_mouse({ winid = chat.win, line = 1, column = 1 }), "blank lookup was consumed")
  assert(
    lookup_calls.tool == 1 and lookup_calls.process == 1 and lookup_calls.image == 1,
    "blank lookup skipped priority"
  )
  chat:_close_image_preview()
  assert(preview_calls.closes == 1 and preview_calls.active == nil, "preview close did not delegate to ImagePreview")

  view.tool_at_row = original_tool_at_row
  view.process_at_row = original_process_at_row
  view.image_at_mouse = original_image_at_mouse
  chat.image_preview.open = preview_open
  chat.image_preview.close = preview_close

  local gesture = assert(
    chat.transcript_view:begin_mouse_gesture({ winid = chat.win, line = 1, column = 1 }),
    "Chat mouse cleanup fixture did not begin"
  )
  assert(gesture == chat.transcript_view.mouse_gesture.generation, "Chat mouse generation was not retained")
  chat:close()
  assert(chat.transcript_view.mouse_gesture == nil, "closing Chat retained an active mouse gesture")

  local preview_buffer = vim.api.nvim_create_buf(false, true)
  table.insert(scratch_buffers, preview_buffer)
  local original_owns_buffer = chat.image_preview.owns_buffer
  local delegated = false
  chat.image_preview.owns_buffer = function(_, buf)
    delegated = true
    return buf == preview_buffer
  end
  assert(chat:owns_buffer(preview_buffer) and delegated, "Chat did not delegate preview ownership to ImagePreview")
  chat.image_preview.owns_buffer = original_owns_buffer

  chat:destroy()
end

local ok, err = xpcall(run, debug.traceback)
for index = #chats, 1, -1 do
  pcall(chats[index].destroy, chats[index])
end
for _, buf in ipairs(scratch_buffers) do
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
if not ok then
  error(err)
end
print("chat_interactions_spec: ok")
