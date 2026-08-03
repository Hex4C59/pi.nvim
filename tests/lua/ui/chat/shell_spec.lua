local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat
local registry = require("pi.ui.chat.registry").default()

local chats = {}
local scratch_buffers = {}

local function track_chat(root)
  local chat = Chat.new(root)
  table.insert(chats, chat)
  return chat
end

local function track_buffer(buf)
  table.insert(scratch_buffers, buf)
  return buf
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function has_highlight(buf, name)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if details.hl_group == name or details.line_hl_group == name then
      return true
    end
  end
  return false
end

local function assert_lines_fit(buf, width, label)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local display_width = vim.api.nvim_strwidth(line)
    assert(
      display_width <= width,
      ("%s line %d has width %d (%d bytes) for %d columns: %s"):format(
        label,
        index,
        display_width,
        #line,
        width,
        line:gsub(" ", "·")
      )
    )
  end
end

local function assert_window_in_editor(win, label)
  assert(win and vim.api.nvim_win_is_valid(win), label .. " window is invalid")
  local position = vim.fn.win_screenpos(win)
  assert(position[1] >= 1 and position[2] >= 1, label .. " starts outside the editor")
  assert(
    position[1] + vim.api.nvim_win_get_height(win) - 1 <= vim.o.lines,
    ("%s crosses the editor bottom edge (row=%d height=%d lines=%d)"):format(
      label,
      position[1],
      vim.api.nvim_win_get_height(win),
      vim.o.lines
    )
  )
  assert(position[2] + vim.api.nvim_win_get_width(win) - 1 <= vim.o.columns, label .. " crosses the editor right edge")
end

local function assert_horizontal_alignment(chat, label)
  local width = vim.api.nvim_win_get_width(chat.win)
  local input = vim.api.nvim_win_get_config(chat.input_area:window())
  local footer = vim.api.nvim_win_get_config(chat.input_area:status_window())
  assert(input.col == 0, label .. " prompt is not aligned with the left edge")
  assert(input.width + 2 == width, label .. " prompt is not aligned with the right edge")
  assert(footer.col == 0 and footer.width == width, label .. " footer is not aligned with the canvas")
  assert(
    input.border[4][1] == "│" and input.border[8][1] == "│",
    label .. " prompt does not use vertical side borders"
  )
end

config.setup({
  chat = {
    position = "right",
    width = 0.55,
    height = 0.45,
    max_widget_height = 4,
    float = { width = 0.8, height = 0.8, border = "rounded" },
  },
})

local function run()
  local root = vim.fs.joinpath(vim.fn.getcwd(), "shell-project")
  local chat = track_chat(root)
  local components = {
    chat.command_menu,
    chat.input_area,
    chat.permission_area,
    chat.widget_area,
    chat.image_backend,
    chat.transcript,
    chat.transcript_view,
    chat.image_preview,
  }
  local seen = {}
  for index, component in ipairs(components) do
    assert(type(component) == "table", ("Chat component %d was not constructed"):format(index))
    assert(not seen[component], ("Chat component %d reused another owner's instance"):format(index))
    seen[component] = true
  end

  local view = chat.transcript_view
  local original = {
    render = view.render,
    schedule_render = view.schedule_render,
    invalidate = view.invalidate,
    invalidate_item = view.invalidate_item,
  }
  local calls = { render = 0, schedule = 0, invalidate = 0, invalidate_item = 0 }
  view.render = function()
    calls.render = calls.render + 1
  end
  view.schedule_render = function()
    calls.schedule = calls.schedule + 1
  end
  view.invalidate = function()
    calls.invalidate = calls.invalidate + 1
  end
  view.invalidate_item = function(_, item)
    assert(item ~= nil, "Transcript invalidation lost the changed item")
    calls.invalidate_item = calls.invalidate_item + 1
  end

  chat:add_user("wiring fixture")
  assert(calls.render == 1, "immediate Transcript changes did not render TranscriptView")
  assert(view:items()[1] == chat.transcript.items[1], "TranscriptView did not read the structured Transcript items")
  chat:start_assistant({ role = "assistant", content = { { type = "text", text = "draft" } } })
  chat:update_assistant(
    { role = "assistant", content = { { type = "text", text = "streaming" } } },
    { type = "text_delta", delta = "ing" }
  )
  assert(calls.schedule == 1, "streaming Transcript changes did not schedule TranscriptView")
  chat:start_tool("shell-wiring-tool", "read", { path = "README.md" })
  assert(calls.invalidate_item > 0, "Transcript item changes did not invalidate TranscriptView's item cache")
  chat.image_backend.on_change()
  assert(
    calls.invalidate == 1 and calls.schedule == 2,
    "image backend changes did not invalidate and schedule the view"
  )

  view.render = original.render
  view.schedule_render = original.schedule_render
  view.invalidate = original.invalidate
  view.invalidate_item = original.invalidate_item
  chat:clear()

  chat:open(false)
  assert(chat:is_open(), "open did not create the complete Chat window set")
  local main_window = chat.win
  local input_window = chat.input_area:window()
  local status_window = chat.input_area:status_window()
  local transcript_buffer = chat.transcript_view:buffer()
  local input_buffer = chat.input_area:buffer()
  local status_buffer = chat.input_area:status_buffer()
  assert(vim.api.nvim_win_get_config(main_window).relative == "", "right layout must use a normal split")
  assert_horizontal_alignment(chat, "right")
  assert(vim.wo[main_window].wrap and vim.wo[main_window].linebreak, "Chat canvas did not enable readable wrapping")
  assert(vim.wo[main_window].breakindent, "Chat canvas did not preserve wrapped-line indentation")
  assert(not vim.wo[main_window].list and not vim.wo[main_window].cursorline, "Chat canvas retained editor artifacts")
  local input_config = vim.api.nvim_win_get_config(input_window)
  local status_config = vim.api.nvim_win_get_config(status_window)
  assert(input_config.relative == "win" and input_config.win == main_window, "prompt is not canvas-relative")
  assert(status_config.relative == "win" and status_config.win == main_window, "status is not canvas-relative")
  assert(status_config.focusable == false, "status window can steal focus")

  chat:open(false)
  assert(
    chat.win == main_window
      and chat.input_area:window() == input_window
      and chat.input_area:status_window() == status_window,
    "opening an open Chat recreated its windows"
  )
  chat:open(true)
  assert(vim.api.nvim_get_current_win() == input_window, "open(true) did not focus the prompt")

  vim.api.nvim_win_close(status_window, true)
  assert(not chat:is_open(), "is_open ignored an invalid component window")
  chat:open(false)
  assert(chat:is_open(), "Chat did not recover from a deleted component window")
  assert(
    chat.transcript_view:buffer() == transcript_buffer
      and chat.input_area:buffer() == input_buffer
      and chat.input_area:status_buffer() == status_buffer,
    "window recovery replaced stable component buffers"
  )

  local owned = { transcript_buffer, input_buffer, status_buffer, chat.command_menu:ensure_buffer() }
  for _, buf in ipairs(owned) do
    assert(chat:owns_buffer(buf), "Chat did not delegate ownership for a component buffer")
  end
  assert(not chat:owns_buffer(nil) and not chat:owns_buffer("invalid"), "invalid ownership input was accepted")
  local unrelated = track_buffer(vim.api.nvim_create_buf(true, false))
  assert(not chat:owns_buffer(unrelated), "Chat claimed an unrelated normal buffer")

  local deleted_command_buffer = chat.command_menu:buffer()
  vim.api.nvim_buf_delete(deleted_command_buffer, { force = true })
  assert(
    not chat:owns_buffer(deleted_command_buffer),
    "Chat retained stale ownership after a component buffer was deleted"
  )
  local replacement_command_buffer = chat.command_menu:ensure_buffer()
  assert(
    replacement_command_buffer ~= deleted_command_buffer and chat:owns_buffer(replacement_command_buffer),
    "Chat did not track the component's replacement buffer"
  )

  chat:set_path(vim.fs.joinpath(root, "lua", "pi", "init.lua"))
  chat:set_title("Session shell\nignored")
  chat:update_state({
    model = { id = "gpt-5.6-sol" },
    thinkingLevel = "high",
    autoCompactionEnabled = false,
  })
  chat:update_stats({
    tokens = { input = 224000, output = 56000 },
    contextUsage = { tokens = 183000, contextWindow = 258000, percent = 71.1 },
    cost = 6.186,
  })
  chat:set_queue({ steering = { "queued correction" }, followUp = { "next prompt" } })
  assert(chat:update_permission_mode("manual"), "authoritative permission update was rejected")
  local input_state = chat.input_area.state_provider()
  local view_state = chat.transcript_view:state()
  assert(chat.path == vim.fs.normalize(vim.fs.joinpath(root, "lua", "pi", "init.lua")), "display path was not updated")
  assert(chat:project_root() == root, "display path update changed the immutable project root")
  assert(chat.title == "Session shell", "session title was not sanitized")
  assert(chat.model == "gpt-5.6-sol" and chat.thinking == "high", "core model state was not projected")
  assert(chat.auto_compaction == false, "auto-compaction state was not projected")
  assert(
    input_state.stats == chat.stats and input_state.queue == chat.queue,
    "InputArea did not consume Chat display state"
  )
  assert(input_state.permission_mode == "manual", "InputArea did not consume reported permission state")
  assert(view_state.model == "gpt-5.6-sol" and view_state.thinking == "high", "TranscriptView state wiring is stale")

  local welcome = buffer_text(transcript_buffer)
  assert(welcome:find("coding agent", 1, true), "opening Chat did not apply the welcome to its buffer")
  assert(welcome:find("gpt-5.6-sol · high", 1, true), "welcome did not consume projected model state")
  assert(welcome:find("manual", 1, true), "welcome did not consume projected permission state")
  assert(has_highlight(transcript_buffer, "PiWelcomeTitle"), "welcome semantic Extmarks were not applied")
  vim.api.nvim_set_hl(0, "PiWelcomeTitle", { fg = "#010101" })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(
    vim.api.nvim_get_hl(0, { name = "PiWelcomeTitle", link = false }).fg ~= 0x010101,
    "ColorScheme did not refresh the global welcome palette"
  )
  chat:add_user("first shell turn")
  local conversation = buffer_text(transcript_buffer)
  assert(
    conversation:find("coding agent", 1, true) < conversation:find(" › first shell turn", 1, true),
    "welcome did not remain above the first conversation turn"
  )

  chat:set_input(table.concat({ "one", "two", "three", "four", "five" }, "\n"))
  input_config = vim.api.nvim_win_get_config(chat.input_area:window())
  status_config = vim.api.nvim_win_get_config(chat.input_area:status_window())
  assert(input_config.height > 3, "growing input did not trigger shell relayout")
  assert(input_config.row + input_config.height + 2 <= status_config.row, "grown input overlaps the status row")
  chat:set_input("")

  local base_overlay_height = chat.overlay_height
  assert(chat:set_widget("shell.widget", { "Shell widget", "reserved row" }, "aboveEditor"), "widget was rejected")
  local widget_window = chat.widget_area:window("aboveEditor")
  local widget_buffer = chat.widget_area:buffer("aboveEditor")
  assert(
    widget_window and widget_buffer and chat:owns_buffer(widget_buffer),
    "Chat did not own the visible widget surface"
  )
  assert(chat.overlay_height > base_overlay_height, "widget height was not reserved by the shell")
  local widget_config = vim.api.nvim_win_get_config(widget_window)
  input_config = vim.api.nvim_win_get_config(chat.input_area:window())
  assert(widget_config.row + widget_config.height <= input_config.row, "widget overlaps the prompt")
  assert_lines_fit(widget_buffer, widget_config.width, "widget")
  chat:set_widget("shell.widget", nil)

  chat:set_input("/mo")
  assert(chat:_update_command_menu(), "command menu did not open in the shell fixture")
  local menu_window = chat.command_menu:window()
  local menu_config = vim.api.nvim_win_get_config(menu_window)
  input_config = vim.api.nvim_win_get_config(chat.input_area:window())
  assert(menu_config.row + menu_config.height <= input_config.row, "command menu is not above the prompt")
  assert(vim.api.nvim_get_current_win() == chat.input_area:window(), "command overlay stole prompt focus")
  assert_lines_fit(chat.command_menu:buffer(), vim.api.nvim_win_get_width(menu_window), "command menu")
  chat:_close_command_menu()
  chat:set_input("")

  chat:confirm({
    id = "shell-permission",
    method = "confirm",
    title = "Allow model Bash command?",
    message = "git status --short --branch && git log -5 --oneline",
  }, function() end)
  input_config = vim.api.nvim_win_get_config(chat.input_area:window())
  local permission_row
  for row, line in ipairs(vim.api.nvim_buf_get_lines(transcript_buffer, 0, -1, false)) do
    if line:find("Do you want to proceed?", 1, true) then
      permission_row = row
      break
    end
  end
  assert(permission_row, "inline permission question is missing from the Chat buffer")
  local permission_position = vim.fn.screenpos(chat.win, permission_row, 1)
  local chat_position = vim.fn.win_screenpos(chat.win)
  assert(permission_position.row > 0, "permission content is outside the visible canvas")
  assert(
    permission_position.row - chat_position[1] < input_config.row,
    "permission content overlaps the reserved prompt area"
  )
  assert(input_config.height == 3, "permission surface did not collapse the inactive prompt")
  chat.permission_area:_resolve(false)
  assert(
    not buffer_text(transcript_buffer):find("Do you want to proceed?", 1, true),
    "resolved permission remained visible"
  )

  chat:_layout()
  assert_window_in_editor(chat.win, "narrow Chat")
  assert_window_in_editor(chat.input_area:window(), "narrow prompt")
  assert_window_in_editor(chat.input_area:status_window(), "narrow status")
  assert_lines_fit(
    chat.input_area:status_buffer(),
    vim.api.nvim_win_get_width(chat.input_area:status_window()),
    "narrow status"
  )

  -- The position matrix protects the same horizontal shell invariant for every supported layout.
  local stable_buffers = {
    transcript = chat.transcript_view:buffer(),
    input = chat.input_area:buffer(),
    status = chat.input_area:status_buffer(),
  }
  chat:set_position("float")
  local main = vim.api.nvim_win_get_config(chat.win)
  input_config = vim.api.nvim_win_get_config(chat.input_area:window())
  status_config = vim.api.nvim_win_get_config(chat.input_area:status_window())
  assert(main.relative == "editor", "float layout did not create an editor-relative canvas")
  assert(input_config.relative == "win" and input_config.win == chat.win, "float prompt lost its canvas parent")
  assert(status_config.relative == "win" and status_config.win == chat.win, "float status lost its canvas parent")
  assert_horizontal_alignment(chat, "float")

  chat:set_position("bottom")
  main = vim.api.nvim_win_get_config(chat.win)
  assert(main.relative == "" and main.split == "below", "bottom layout did not create a bottom split")
  assert_horizontal_alignment(chat, "bottom")
  assert_window_in_editor(chat.win, "short bottom Chat")
  assert_window_in_editor(chat.input_area:window(), "short bottom prompt")
  assert_window_in_editor(chat.input_area:status_window(), "short bottom status")
  local bottom_height = vim.api.nvim_win_get_height(chat.win)
  chat:confirm({ id = "bottom-permission", method = "confirm", title = "Confirm", message = "fixture" }, function() end)
  assert(vim.api.nvim_win_get_height(chat.win) >= 16, "permission UI did not expand the short bottom split")
  chat.permission_area:_resolve(false)
  assert(vim.api.nvim_win_get_height(chat.win) == bottom_height, "bottom split height was not restored")

  local tab_count = vim.fn.tabpagenr("$")
  chat:set_position("tab")
  assert(vim.api.nvim_win_get_config(chat.win).relative == "", "tab layout must use a normal window")
  assert(vim.fn.tabpagenr("$") == tab_count + 1, "tab layout did not create a dedicated tab")
  assert_horizontal_alignment(chat, "tab")
  assert(
    chat.transcript_view:buffer() == stable_buffers.transcript
      and chat.input_area:buffer() == stable_buffers.input
      and chat.input_area:status_buffer() == stable_buffers.status,
    "responsive relayout replaced component-owned buffers"
  )

  assert(registry.welcome_animation_timer ~= nil, "open Chat did not start the shared welcome timer")
  local frame = registry.welcome_animation_frame
  assert(
    vim.wait(1000, function()
      return registry.welcome_animation_frame ~= frame
    end, 20),
    "welcome animation did not advance while Chat was open"
  )

  local other = track_chat(vim.fs.joinpath(vim.fn.getcwd(), "shell-other-project"))
  other:open(false)
  local other_buffer = other.transcript_view:buffer()
  assert(other:owns_buffer(other_buffer), "second Chat did not own its transcript")
  assert(not chat:owns_buffer(other_buffer), "one project Chat claimed another project's buffer")
  chat:close()
  assert(registry.welcome_animation_timer ~= nil, "closing one Chat stopped another Chat's welcome animation")
  other:close()
  assert(registry.welcome_animation_timer == nil, "closing the last Chat retained the shared welcome timer")

  local destroyed_input = chat.input_area:buffer()
  chat:destroy()
  assert(not chat:owns_buffer(destroyed_input), "destroyed Chat retained component buffer ownership")
  other:destroy()
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
print("chat_shell_spec: ok")
