local config = require("pi.config")
local renderer = require("pi.ui.render")
local command_menu = require("pi.ui.command_menu")
local input_area = require("pi.ui.input")
local permission_panel = require("pi.ui.permission")
local widget_panel = require("pi.ui.widget")
local permission_modes = require("pi.permission_mode")
local image_backend = require("pi.ui.image.backend")
local text_content = require("pi.message").text_content
local Transcript = require("pi.ui.transcript").Transcript
local TranscriptView = require("pi.ui.transcript.view").TranscriptView
local ImagePreview = require("pi.ui.image.window").ImagePreview
local registry = require("pi.ui.chat.registry").default()
local Shell = require("pi.ui.chat.shell").Shell

local M = {}
local Chat = {}
local shell_fields = {
  win = true,
  position = true,
  title = true,
  permission_restore_height = true,
  overlay_height = true,
}

Chat.__index = function(self, key)
  local value = Chat[key]
  if value ~= nil then
    return value
  end
  local shell = rawget(self, "shell")
  if shell and shell_fields[key] then
    return shell[key]
  end
end

local namespace = registry.namespace
local ui_group = registry.group

local function initial_permission_mode()
  local security_mode = (config.get().security or {}).mode
  if security_mode == "confirm" then
    return nil
  end
  return permission_modes.default_for_security(security_mode)
end

local function action(actions, name)
  return type(actions) == "table" and type(actions[name]) == "function" and actions[name] or function() end
end

function Chat.new(root, frontend_actions)
  registry:prepare()
  local chat = setmetatable({
    root = root,
    pending_images = {},
    tools_expanded = false,
    hide_thinking = true,
    process_expanded = false,
    commands = {},
    queue = { steering = {}, followUp = {} },
    animation_frame = 0,
    animation_timer = nil,
    activity_started_at = nil,
    path = root,
    activity = "starting",
    model = "loading",
    thinking = "-",
    reported_permission_mode = initial_permission_mode(),
    auto_compaction = true,
    stats = {
      tokens = {},
      contextUsage = {},
      cost = 0,
    },
  }, Chat)
  chat.command_menu = command_menu.CommandMenu.new({
    root = root,
    namespace = namespace,
    name_buffer = input_area.name_buffer,
    truncate_display = input_area.truncate_display,
    commands = function()
      return chat.commands
    end,
    main_window = function()
      return chat.shell and chat.shell:window() or nil
    end,
    input_buffer = function()
      return chat.input_area and chat.input_area:buffer() or nil
    end,
    input_window = function()
      return chat.input_area and chat.input_area:window() or nil
    end,
  })
  chat.input_area = input_area.InputArea.new({
    root = root,
    namespace = namespace,
    ui_group = ui_group,
    main_window = function()
      return chat.shell and chat.shell:window() or nil
    end,
    state = function()
      return {
        active = chat:_is_active(),
        activity = chat.activity,
        activity_text = chat:_activity_text(),
        animation_frame = chat.animation_frame,
        stats = chat.stats,
        queue = chat.queue,
        permission_mode = chat:permission_mode(),
        permission_mode_label = chat:permission_mode_label(),
        model = chat.model,
        thinking = chat.thinking,
        pending_image_count = #chat.pending_images,
      }
    end,
    actions = {
      layout = function()
        chat:_layout()
      end,
      close_command_menu = function()
        chat:_close_command_menu()
      end,
      update_command_menu = function()
        return chat:_update_command_menu()
      end,
      command_menu_visible = function()
        return chat:_command_menu_visible()
      end,
      select_command = function(delta)
        return chat:_select_command(delta)
      end,
      accept_command_completion = function()
        return chat:_accept_command_completion()
      end,
      take_image_attachments = function()
        return chat:take_image_attachments()
      end,
      add_image_attachment = function(image)
        return chat:add_image_attachment(image)
      end,
      submit = action(frontend_actions, "submit"),
      abort = action(frontend_actions, "abort"),
      select_model = action(frontend_actions, "select_model"),
      cycle_model = action(frontend_actions, "cycle_model"),
      cycle_permission_mode = action(frontend_actions, "cycle_permission_mode"),
      cycle_thinking_level = action(frontend_actions, "cycle_thinking_level"),
      close = function()
        chat:close()
      end,
      toggle_tools = function()
        chat:toggle_tools()
      end,
      toggle_thinking = function()
        chat:toggle_thinking()
      end,
      copy_last_assistant = function()
        chat:copy_last_assistant()
      end,
      left_mouse = function()
        return chat:_handle_left_mouse()
      end,
    },
  })
  chat.permission_area = permission_panel.PermissionPanel.new({
    root = root,
    main_window = function()
      return chat.shell and chat.shell:window() or nil
    end,
    transcript_buffer = function()
      return chat.transcript_view and chat.transcript_view:buffer() or nil
    end,
    input_window = function()
      return chat.input_area:window()
    end,
    actions = {
      render = function()
        chat:_render_transcript()
      end,
      layout = function()
        chat:_layout()
      end,
      close_command_menu = function()
        chat:_close_command_menu()
      end,
    },
  })
  chat.widget_area = widget_panel.WidgetArea.new({
    root = root,
    namespace = namespace,
    main_window = function()
      return chat.shell and chat.shell:window() or nil
    end,
    actions = {
      render = function()
        chat:_render_transcript()
      end,
      layout = function()
        chat:_layout()
      end,
    },
  })
  chat.image_backend = image_backend.new({
    on_change = function()
      if chat.transcript_view then
        chat.transcript_view:invalidate()
        chat.transcript_view:schedule_render()
      end
    end,
  })
  chat.transcript_view = TranscriptView.new({
    root = root,
    output = config.get().output,
    image_backend = chat.image_backend,
    ui_group = ui_group,
    window = function()
      return chat.win
    end,
    items = function()
      return chat.transcript and chat.transcript.items or {}
    end,
    state = function()
      return {
        hide_thinking = chat.hide_thinking,
        tools_expanded = chat.tools_expanded,
        process_expanded = chat.process_expanded,
        model = chat.model,
        thinking = chat.thinking,
        permission_mode = chat:permission_mode() or "syncing",
        overlay_height = chat.overlay_height or 0,
      }
    end,
    widget_content = function(width)
      return chat.widget_area:transcript_content(width)
    end,
    permission_content = function(width)
      return chat.permission_area:transcript_content(width)
    end,
    body_bytes = function()
      return (chat.transcript and chat.transcript.non_tool_retained_bytes or 0)
        + (chat.transcript and chat.transcript.tool_retained_bytes or 0)
    end,
    materialize = function()
      if chat.transcript then
        chat.transcript:materialize_pending_bash()
      end
    end,
    process_active = function()
      return chat:_process_is_active()
    end,
    track_image = function(block)
      return chat.transcript:_track_image(block)
    end,
    refresh_image_accounting = function(item, block)
      return chat.transcript:_refresh_image_accounting(item, block)
    end,
    actions = {
      close = function()
        chat:close()
      end,
      focus_input = function()
        chat:_focus_input()
      end,
      toggle_tools = function()
        chat:toggle_tools()
      end,
      toggle_thinking = function()
        chat:toggle_thinking()
      end,
      copy_last_assistant = function()
        chat:copy_last_assistant()
      end,
      left_mouse = function()
        input_area.dispatch_left_mouse(function()
          return chat:_handle_left_mouse()
        end)
      end,
      open_image_preview = function(descriptor)
        return chat:_open_image_preview(descriptor)
      end,
      abort = action(frontend_actions, "abort"),
      select_model = action(frontend_actions, "select_model"),
      cycle_model = action(frontend_actions, "cycle_model"),
      cycle_thinking_level = action(frontend_actions, "cycle_thinking_level"),
    },
  })
  chat.transcript = Transcript.new({
    output = config.get().output,
    images = function()
      return config.get().images
    end,
    on_change = function(immediate)
      chat.transcript_view:set_image_backend(chat.image_backend)
      chat.image_preview:set_backend(chat.image_backend)
      if immediate then
        chat.transcript_view:render()
      else
        chat.transcript_view:schedule_render()
      end
    end,
    on_invalidate = function(item)
      if item then
        chat.transcript_view:invalidate_item(item)
      else
        chat.transcript_view:invalidate()
      end
    end,
    on_input_change = function()
      chat.input_area:update_frame()
    end,
    projection_bytes = function()
      return chat.transcript_view:projection_bytes()
    end,
  })
  chat.image_preview = ImagePreview.new({
    root = root,
    backend = chat.image_backend,
    ui_group = ui_group,
    border = function()
      return ((config.get().chat or {}).float or {}).border or "rounded"
    end,
    track_image = function(block)
      return chat.transcript:_track_image(block)
    end,
    release_image = function(block)
      chat.transcript:release_image(block)
    end,
  })
  chat.shell = Shell.new({
    input_window = function()
      return chat.input_area:window()
    end,
    status_window = function()
      return chat.input_area:status_window()
    end,
    input_window_config = function(row, width, height)
      return chat.input_area:window_config(row, width, height)
    end,
    desired_input_height = function()
      return chat.input_area:desired_input_height()
    end,
    set_input_windows = function(input_win, status_win)
      chat.input_area:set_windows(input_win, status_win)
    end,
    ensure_input_buffer = function()
      return chat.input_area:ensure_input_buffer()
    end,
    ensure_status_buffer = function()
      return chat.input_area:ensure_status_buffer()
    end,
    close_input_windows = function()
      chat.input_area:close_windows()
    end,
    update_input_chrome = function()
      chat.input_area:update_chrome()
    end,
    render_status = function()
      chat.input_area:render_status()
    end,
    permission_active = function()
      return chat.permission_area:active()
    end,
    set_permission_height = function(height)
      chat.permission_area:set_available_height(height)
    end,
    cancel_permissions = function()
      chat.permission_area:cancel_all()
    end,
    command_menu_visible = function()
      return chat.command_menu:visible()
    end,
    layout_command_menu = function()
      return chat.command_menu:layout()
    end,
    close_command_menu = function()
      chat.command_menu:close()
    end,
    measure_widgets = function(width, available)
      return chat.widget_area:measure(width, available)
    end,
    layout_widgets = function(width, input_row, input_height, above_height, below_height)
      chat.widget_area:layout(width, input_row, input_height, above_height, below_height)
    end,
    close_widget_windows = function()
      chat.widget_area:close_windows()
    end,
    ensure_transcript_buffer = function()
      return chat.transcript_view:ensure_buffer()
    end,
    update_transcript_width = function(width)
      return chat.transcript_view:update_layout_width(width)
    end,
    reset_transcript_width = function()
      chat.transcript_view:reset_layout_width()
    end,
    clear_transcript_images = function()
      chat.transcript_view:clear_images()
    end,
    render_transcript = function()
      chat:_render_transcript()
    end,
    set_transcript_title = function(title)
      chat.transcript_view:set_title(title)
    end,
    sync_image_backends = function()
      chat.transcript_view:set_image_backend(chat.image_backend)
      chat.image_preview:set_backend(chat.image_backend)
    end,
    close_image_preview = function()
      chat:_close_image_preview()
    end,
    stop_activity_animation = function()
      chat:_stop_animation()
    end,
    sync_activity_animation = function()
      chat:_sync_animation()
    end,
    sync_welcome_animation = function()
      registry:sync_welcome_animation()
    end,
    focus_input = function()
      chat:_focus_input()
    end,
  })
  chat.registry_entry = {
    is_open = function()
      return chat:is_open()
    end,
    layout = function()
      chat:_layout()
    end,
    window = function()
      return chat.shell:window()
    end,
    clamp = function()
      chat:_clamp_transcript_view()
    end,
    clear_images = function()
      chat.image_backend:clear()
    end,
  }
  registry:register(root, chat.registry_entry)
  return chat
end

function Chat:retained_transcript_bytes()
  return self.transcript:retained_transcript_bytes()
end

function Chat:project_root()
  return self.root
end

function Chat:has_active_permission_request()
  return self.permission_area:active()
end

function Chat:current_layout()
  return self.shell:current_layout()
end

function Chat:process_details_enabled()
  return self.process_expanded == true
end

function Chat:display_state()
  return {
    layout = self:current_layout(),
    process_expanded = self:process_details_enabled(),
    permission_mode = self:permission_mode(),
    permission_mode_label = self:permission_mode_label(),
  }
end

function Chat:reset_session_projection()
  self.transcript.history_loaded = false
  self:clear()
  self:update_stats({ tokens = {}, contextUsage = {}, cost = 0 })
end

function Chat:_invalidate_cached_item(item)
  self.transcript_view:invalidate_item(item)
end
function Chat:is_open()
  return self.shell:is_open()
end

function Chat:owns_buffer(bufnr)
  return self.transcript_view:owns_buffer(bufnr)
    or self.input_area:owns_buffer(bufnr)
    or self.command_menu:owns_buffer(bufnr)
    or self.widget_area:owns_buffer(bufnr)
    or self.image_preview:owns_buffer(bufnr)
end

function Chat:_stop_animation()
  if self.animation_timer then
    self.animation_timer:stop()
    self.animation_timer:close()
    self.animation_timer = nil
  end
end

function Chat:_is_active()
  return self.activity ~= "idle"
    and self.activity ~= "starting"
    and self.activity ~= "stopped"
    and self.activity ~= "error"
end

function Chat:_process_is_active()
  if self:_is_active() or self.transcript.streaming_assistant then
    return true
  end
  for index = #self.transcript.items, 1, -1 do
    local item = self.transcript.items[index]
    if item.type == "user" then
      break
    elseif item.type == "tool" and item.state == "pending" then
      return true
    end
  end
  return false
end

function Chat:_activity_text()
  if self:_is_active() then
    local elapsed = self.activity_started_at and ((vim.uv.hrtime() - self.activity_started_at) / 1000000000) or 0
    local duration = renderer.format_elapsed(elapsed)
    local labels = {
      working = "Thinking",
      compacting = "Compacting",
    }
    local label = self.activity == "working" and self.transcript.reasoning_header
      or labels[self.activity]
      or self.activity:gsub("^%l", string.upper)
    return label .. " · " .. duration
  end
  return self.activity
end

function Chat:_input_window_config(row, width, height)
  return self.input_area:window_config(row, width, height)
end
function Chat:_sync_animation()
  if not self:_is_active() or not self:is_open() then
    self:_stop_animation()
    return
  end
  if self.animation_timer then
    return
  end
  self.animation_timer = vim.uv.new_timer()
  self.animation_timer:start(
    120,
    110,
    vim.schedule_wrap(function()
      if not self:_is_active() or not self:is_open() then
        self:_stop_animation()
        return
      end
      self.animation_frame = self.animation_frame + 1
      self.input_area:update_frame()
    end)
  )
end

function Chat:close()
  self.shell:close()
end

function Chat:destroy()
  if self.destroyed then
    return
  end
  self.destroying = true
  self:close()
  self.transcript:destroy()
  self.transcript_view:destroy()
  self.image_preview:destroy()
  self.pending_images = {}
  self.widget_area:destroy()
  self.command_menu:destroy()
  self.input_area:destroy()
  self.permission_area:destroy()
  registry:unregister(self.root)
  self.registry_entry = nil
  self.destroyed = true
end

function Chat:set_path(path)
  if not path or path == "" or path:find("://", 1, true) then
    return
  end
  self.path = vim.fs.normalize(path)
  self:_render_status()
end

function Chat:set_activity(activity)
  local was_active = self:_is_active()
  local previous = self.activity
  self.activity = activity or "idle"
  if self:_is_active() then
    if not was_active or previous ~= self.activity or not self.activity_started_at then
      self.activity_started_at = vim.uv.hrtime()
      self.animation_frame = 0
    end
  else
    self.activity_started_at = nil
  end
  if self.activity ~= "working" then
    self.transcript:clear_reasoning()
  end
  self:_sync_animation()
  self:_layout()
  if was_active ~= self:_is_active() and self.transcript_view:has_buffer() then
    self:_render_transcript()
  end
end

function Chat:update_state(state)
  state = state or {}
  if state.model then
    self.model = state.model.id or state.model.name or self.model
  end
  self.thinking = state.thinkingLevel or self.thinking
  if state.autoCompactionEnabled ~= nil then
    self.auto_compaction = state.autoCompactionEnabled
  end
  if state.isCompacting then
    self.activity = "compacting"
  elseif state.isStreaming then
    self.activity = "working"
  else
    self.activity = "idle"
  end
  if self:_is_active() and not self.activity_started_at then
    self.activity_started_at = vim.uv.hrtime()
    self.animation_frame = 0
  elseif not self:_is_active() then
    self.activity_started_at = nil
  end
  if self.activity ~= "working" then
    self.transcript:clear_reasoning()
  end
  self:_sync_animation()
  self:_update_input_chrome()
  self:_render_status()
  if self.transcript_view:has_buffer() then
    self:_render_transcript()
  end
end

function Chat:update_stats(stats)
  self.stats = stats or self.stats
  self:_render_status()
end

function Chat:set_queue(queue)
  self.queue = queue or { steering = {}, followUp = {} }
  self:_update_input_chrome()
end

function Chat:permission_mode()
  return permission_modes.normalize(self.reported_permission_mode)
end

function Chat:permission_mode_label()
  return permission_modes.label(self:permission_mode())
end

function Chat:update_permission_mode(mode)
  mode = permission_modes.normalize(mode)
  if not mode then
    return false
  end
  if self.reported_permission_mode == mode then
    return true
  end
  self.reported_permission_mode = mode
  self:_close_command_menu()
  self:_update_input_chrome()
  self:_render_status()
  if self.transcript_view:has_buffer() then
    self:_render_transcript()
  end
  return true
end

function Chat:reset_permission_mode()
  self.reported_permission_mode = initial_permission_mode()
  self:_update_input_chrome()
  self:_render_status()
end

function Chat:set_commands(commands)
  self.commands = commands or {}
  if self:_command_menu_visible() then
    self:_update_command_menu()
  end
end

function Chat:_command_completion_context()
  return self.command_menu:completion_context()
end

function Chat:_command_menu_visible()
  return self.command_menu:visible()
end

function Chat:_close_command_menu()
  local visible = self.command_menu:visible()
  self.command_menu:close()
  if visible then
    self:_layout()
  end
end

function Chat:_layout_command_menu()
  return self.command_menu:layout()
end

function Chat:_update_command_menu()
  local visible = self.command_menu:update()
  self:_layout()
  return visible
end

function Chat:_select_command(delta)
  return self.command_menu:select(delta)
end

function Chat:_accept_command_completion()
  local accepted = self.command_menu:accept()
  if accepted then
    self:_layout()
  end
  return accepted
end

function Chat:set_widget(key, lines, placement)
  return self.widget_area:set(key, lines, placement)
end

function Chat:clear_widgets()
  self.widget_area:clear()
end

function Chat:set_title(title)
  return self.shell:set_title(title)
end

function Chat:_update_input_chrome()
  self.input_area:update_chrome()
end
function Chat:_status_text(width)
  return self.input_area:status_text(width)
end
function Chat:_render_status()
  self.input_area:render_status()
end
function Chat:_desired_input_height()
  return self.input_area:desired_input_height()
end
function Chat:_layout_main()
  return self.shell:layout_main()
end
function Chat:_layout()
  return self.shell:layout()
end
function Chat:set_input(text)
  self.input_area:set_input(text)
end
function Chat:_focus_input()
  if self.permission_area:active() then
    self.permission_area:focus()
    return
  end
  self.input_area:focus()
end

function Chat:confirm(request, callback)
  self:open(false)
  local display = vim.deepcopy(request)
  display.options = { "Block", "Allow once" }
  self.permission_area:show(display, function(decision)
    callback(decision == "Allow once")
  end)
end

function Chat:select_permission(request, callback)
  self:open(false)
  self.permission_area:show(request, callback)
end
function Chat:_close_image_preview()
  self.image_preview:set_backend(self.image_backend)
  self.image_preview:close()
end

function Chat:_open_image_preview(descriptor)
  self.image_preview:set_backend(self.image_backend)
  return self.image_preview:open(descriptor)
end

function Chat:set_position(position)
  return self.shell:set_position(position)
end

function Chat:open(focus_input)
  return self.shell:open(focus_input)
end

function Chat:_clamp_transcript_view()
  return self.transcript_view:clamp()
end
function Chat:_render_transcript()
  if self.destroying then
    return
  end
  return self.transcript_view:render()
end
function Chat:clear()
  self.transcript:clear()
  self.transcript_view:clear()
  self:reset_permission_mode()
  self.pending_images = {}
  self.widget_area:clear()
  self.input_area:render_attachments()
end
function Chat:add_user(text, content)
  self.transcript:add_user(text, content)
end
function Chat:validate_image_attachments(images)
  return self.transcript:validate_image_attachments(images)
end
function Chat:add_image_attachment(image)
  if type(image) ~= "table" or image.type ~= "image" then
    return false, "image attachment is invalid"
  end
  local combined = vim.list_slice(self.pending_images)
  table.insert(combined, image)
  local valid, err = self:validate_image_attachments(combined)
  if not valid then
    return false, err
  end
  table.insert(self.pending_images, image)
  self.input_area:render_attachments()
  return true
end

function Chat:take_image_attachments()
  local images = self.pending_images
  self.pending_images = {}
  self.input_area:render_attachments()
  return images
end

function Chat:restore_image_attachments(images)
  local combined = vim.list_slice(self.pending_images)
  vim.list_extend(combined, images or {})
  local valid, err = self:validate_image_attachments(combined)
  if not valid then
    return false, err
  end
  self.pending_images = combined
  self.input_area:render_attachments()
  return true
end

function Chat:localize_images(images)
  return self.transcript:localize_images(images)
end
function Chat:start_assistant(message)
  self.transcript:start_assistant(message)
end
function Chat:update_assistant(message, message_event)
  self.transcript:update_assistant(message, message_event)
end
function Chat:end_assistant(message)
  self.transcript:end_assistant(message)
end
function Chat:start_tool(id, name, args)
  self.transcript:start_tool(id, name, args)
end
function Chat:update_tool(id, result)
  self.transcript:update_tool(id, result)
end
function Chat:append_bash_delta(id, delta)
  self.transcript:append_bash_delta(id, delta)
end
function Chat:end_bash(id, data, is_error)
  self.transcript:end_bash(id, data, is_error)
end
function Chat:end_tool(id, result, is_error)
  self.transcript:end_tool(id, result, is_error)
end
function Chat:add_status(text, is_error)
  self.transcript:add_status(text, is_error)
end
function Chat:_tool_at_row(row)
  return self.transcript_view:tool_at_row(row)
end
function Chat:_process_at_row(row)
  return self.transcript_view:process_at_row(row)
end
function Chat:_image_at_row(row)
  return self.transcript_view:image_at_row(row)
end
function Chat:_image_at_mouse(mouse)
  return self.transcript_view:image_at_mouse(mouse)
end
function Chat:_tool_under_cursor()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or vim.api.nvim_get_current_win() ~= self.win then
    return nil
  end
  return self:_tool_at_row(vim.api.nvim_win_get_cursor(self.win)[1])
end

function Chat:_toggle_tool(item)
  self:_invalidate_cached_item(item)
  local expanded = item.expanded
  if expanded == nil then
    expanded = self.tools_expanded
  end
  item.expanded = not expanded
end

function Chat:_handle_left_mouse(mouse)
  mouse = mouse or vim.fn.getmousepos()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or mouse.winid ~= self.win then
    return false
  end
  local image = self:_image_at_mouse(mouse)
  if image then
    pcall(vim.api.nvim_win_set_cursor, self.win, { image.row + 1, image.col })
    return self:_open_image_preview(image)
  end
  local item = self:_tool_at_row(mouse.line)
  local process = not item and self:_process_at_row(mouse.line) or nil
  if not item and not process then
    return false
  end

  local buf = self.transcript_view:buffer()
  local row = math.max(1, math.min(tonumber(mouse.line) or 1, vim.api.nvim_buf_line_count(buf)))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local column = math.max(0, math.min((tonumber(mouse.column) or 1) - 1, #line))
  pcall(vim.api.nvim_win_set_cursor, self.win, { row, column })
  if item then
    self:_toggle_tool(item)
    self:_render_transcript()
  else
    self:toggle_process()
  end
  return true
end

function Chat:toggle_process()
  self.process_expanded = not self.process_expanded
  self.tools_expanded = self.process_expanded
  self.hide_thinking = not self.process_expanded
  for _, candidate in ipairs(self.transcript.items) do
    if candidate.type == "tool" then
      candidate.expanded = nil
    end
  end
  self:_render_transcript()
end

function Chat:toggle_tools()
  local item = self:_tool_under_cursor()
  if item then
    self:_toggle_tool(item)
  else
    self:toggle_process()
    return
  end
  self:_render_transcript()
end

function Chat:toggle_thinking()
  self:toggle_process()
end

function Chat:copy_last_assistant()
  for index = #self.transcript.items, 1, -1 do
    local item = self.transcript.items[index]
    if item.type == "assistant" then
      local text = text_content(item.message.content)
      if text ~= "" then
        vim.fn.setreg("+", text)
        vim.notify("Copied the last Pi response", vim.log.levels.INFO, { title = "Pi" })
        return
      end
    end
  end
end

function Chat:render_history(messages)
  self.transcript:render_history(messages)
end

M.Chat = Chat
return M
