local config = require("pi.config")
local renderer = require("pi.ui.render")
local highlights = require("pi.ui.highlights")
local command_menu = require("pi.ui.command_menu")
local input_area = require("pi.ui.input")
local permission_panel = require("pi.ui.permission")
local widget_panel = require("pi.ui.widget")
local permission_modes = require("pi.permission_mode")
local image_data = require("pi.ui.image")
local image_backend = require("pi.ui.image_backend")
local text_content = require("pi.message").text_content
local Transcript = require("pi.ui.transcript").Transcript
local TranscriptView = require("pi.ui.transcript_view").TranscriptView
local ImagePreview = require("pi.ui.image_preview").ImagePreview

local M = {}
local Chat = {}
Chat.__index = Chat

local namespace = vim.api.nvim_create_namespace("pi.nvim")
local instances = setmetatable({}, { __mode = "v" })
local welcome_animation_timer = nil
local welcome_animation_frame = 0

local function initial_permission_mode()
  local security_mode = (config.get().security or {}).mode
  if security_mode == "confirm" then
    return nil
  end
  return permission_modes.default_for_security(security_mode)
end

local function update_welcome_logo_highlights()
  local welcome_logo_palette, welcome_logo_background = highlights.welcome_palette()
  if #welcome_logo_palette == 0 then
    return
  end

  for index = 1, 4 do
    local palette_index = (index + welcome_animation_frame - 2) % #welcome_logo_palette + 1
    vim.api.nvim_set_hl(0, "PiWelcomeLogo" .. index, {
      fg = welcome_logo_palette[palette_index],
      bg = welcome_logo_background,
      bold = true,
    })
  end
end

local function has_open_chat()
  for _, chat in pairs(instances) do
    if chat.is_open and chat:is_open() then
      return true
    end
  end
  return false
end

local function stop_welcome_animation()
  if welcome_animation_timer then
    welcome_animation_timer:stop()
    welcome_animation_timer:close()
    welcome_animation_timer = nil
  end
end

local function sync_welcome_animation()
  if not has_open_chat() then
    stop_welcome_animation()
    return
  end
  if welcome_animation_timer then
    return
  end

  welcome_animation_timer = vim.uv.new_timer()
  welcome_animation_timer:start(
    360,
    360,
    vim.schedule_wrap(function()
      if not has_open_chat() then
        stop_welcome_animation()
        return
      end
      local welcome_logo_palette = highlights.welcome_palette()
      welcome_animation_frame = (welcome_animation_frame + 1) % math.max(1, #welcome_logo_palette)
      update_welcome_logo_highlights()
    end)
  )
end

local ui_group = vim.api.nvim_create_augroup("PiNvimUI", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = ui_group,
  callback = function()
    highlights.setup()
    image_data.refresh_preview_highlights()
    update_welcome_logo_highlights()
  end,
})
vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = ui_group,
  callback = function()
    for _, chat in pairs(instances) do
      if chat:is_open() then
        chat:_layout()
      end
    end
  end,
})
vim.api.nvim_create_autocmd("WinScrolled", {
  group = ui_group,
  callback = function(event)
    local win = tonumber(event.match)
    for _, chat in pairs(instances) do
      if chat.win == win and chat._clamp_transcript_view then
        chat:_clamp_transcript_view()
        break
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = ui_group,
  callback = function()
    stop_welcome_animation()
    for _, chat in pairs(instances) do
      if chat.image_backend then
        chat.image_backend:clear()
      end
    end
  end,
})

function Chat.new(root)
  highlights.setup()
  update_welcome_logo_highlights()
  local chat = setmetatable({
    root = root,
    win = nil,
    permission_restore_height = nil,
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
    title = "pi",
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
  chat.command_menu = command_menu.CommandMenu.new(chat, {
    namespace = namespace,
    name_buffer = input_area.name_buffer,
    truncate_display = input_area.truncate_display,
    instances = instances,
  })
  chat.input_area = input_area.InputArea.new(chat, {
    namespace = namespace,
    ui_group = ui_group,
  })
  chat.permission_area = permission_panel.PermissionPanel.new(chat, {
    namespace = namespace,
  })
  chat.widget_area = widget_panel.WidgetArea.new(chat, {
    namespace = namespace,
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
        input_area.dispatch_left_mouse(chat)
      end,
      open_image_preview = function(descriptor)
        return chat:_open_image_preview(descriptor)
      end,
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
  instances[root] = chat
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
  return self.position or config.get().chat.position
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
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and self.input_area:window() ~= nil
    and vim.api.nvim_win_is_valid(self.input_area:window())
    and self.input_area:status_window() ~= nil
    and vim.api.nvim_win_is_valid(self.input_area:status_window())
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
  self:_stop_animation()
  self:_close_image_preview()
  if self.image_backend then
    self.transcript_view:clear_images()
  end
  self.permission_area:cancel_all()
  self.command_menu:close()
  self.widget_area:close_windows()
  self.input_area:close_windows()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.permission_restore_height = nil
  self.win = nil
  self.transcript_view:reset_layout_width()
  sync_welcome_animation()
end

function Chat:destroy()
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
  instances[self.root] = nil
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
  title = tostring(title or ""):gsub("[\r\n].*$", "")
  title = vim.trim(title)
  if title == "" then
    title = "pi"
  end
  self.title = vim.fn.strcharpart(title, 0, 80)
  self.transcript_view:set_title(self.title)
  self:_layout_main()
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
  if self.position ~= "float" or not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local options = config.get().chat.float or {}
  local available_width = math.max(42, vim.o.columns - 4)
  local available_height = math.max(12, vim.o.lines - vim.o.cmdheight - 4)
  local width = math.min(available_width, math.max(42, math.floor(vim.o.columns * (options.width or 0.84))))
  local height = math.min(available_height, math.max(12, math.floor(vim.o.lines * (options.height or 0.86))))
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = options.border or "rounded",
    title = { { (" %s "):format(self.title or "pi"), "PiPanelTitle" } },
    title_pos = "center",
    zindex = 40,
  })
end
function Chat:_layout()
  self:_layout_main()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local input_win = self.input_area:window()
  local status_win = self.input_area:status_window()
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then
    return
  end
  if not status_win or not vim.api.nvim_win_is_valid(status_win) then
    return
  end

  local permission_active = self.permission_area:active()
  if self.position == "bottom" then
    if permission_active then
      if not self.permission_restore_height then
        self.permission_restore_height = vim.api.nvim_win_get_height(self.win)
      end
      local maximum = math.max(10, vim.o.lines - vim.o.cmdheight - 3)
      pcall(vim.api.nvim_win_set_height, self.win, math.min(16, maximum))
    elseif self.permission_restore_height then
      pcall(vim.api.nvim_win_set_height, self.win, self.permission_restore_height)
      self.permission_restore_height = nil
    end
  end

  local width = vim.api.nvim_win_get_width(self.win)
  local height = vim.api.nvim_win_get_height(self.win)
  local transcript_width_changed = self.transcript_view:update_layout_width(width)
  local footer_height = 1
  local widget_hidden = permission_active or self:_command_menu_visible()
  local widget_width = width
  local widget_budget = widget_hidden and 0 or math.max(0, height - footer_height - 7)
  local above_widget_height, below_widget_height = self.widget_area:measure(widget_width, widget_budget)
  local widget_height = above_widget_height + below_widget_height
  local available_input = math.max(1, height - footer_height - 4 - widget_height)
  local input_height = math.min(self:_desired_input_height(), available_input)
  if permission_active then
    input_height = math.min(input_height, 3)
  end
  local input_row = math.max(0, height - footer_height - below_widget_height - input_height - 2)
  local footer_row = math.max(0, height - footer_height)
  self.permission_area:set_available_height(input_row)

  local input_config = self:_input_window_config(input_row, math.max(1, width - 2), input_height)
  input_config.focusable = not permission_active
  vim.api.nvim_win_set_config(input_win, input_config)
  vim.api.nvim_win_set_config(status_win, {
    relative = "win",
    win = self.win,
    row = footer_row,
    col = 0,
    width = width,
    height = footer_height,
    style = "minimal",
    focusable = false,
    zindex = 51,
  })
  if self:_command_menu_visible() then
    self:_layout_command_menu()
  end

  self.widget_area:layout(widget_width, input_row, input_height, above_widget_height, below_widget_height)
  local overlay_height = input_height + footer_height + 2 + widget_height
  local overlay_changed = self.overlay_height ~= overlay_height
  self.overlay_height = overlay_height
  self:_render_status()
  if overlay_changed or transcript_width_changed then
    self:_render_transcript()
  end
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
local function style_window(win, normal_group)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].list = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winhighlight = ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,WinSeparator:PiPanelBorder,FloatBorder:PiPanelBorder"):format(
    normal_group,
    normal_group,
    normal_group
  )
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
  if not vim.tbl_contains({ "right", "bottom", "tab", "float" }, position) then
    error("pi.nvim: layout must be right, bottom, tab, or float")
  end
  local reopen = self:is_open()
  if reopen then
    self:close()
  end
  self.position = position
  if reopen then
    self:open()
  end
end

function Chat:open(focus_input)
  self.transcript_view:set_image_backend(self.image_backend)
  self.image_preview:set_backend(self.image_backend)
  local buf = self.transcript_view:ensure_buffer()
  local input_buf = self.input_area:ensure_input_buffer()
  local status_buf = self.input_area:ensure_status_buffer()
  if self:is_open() then
    if focus_input ~= false then
      self:_focus_input()
    end
    return
  end

  self:close()
  local chat = config.get().chat
  self.position = self.position or chat.position
  if self.position == "tab" then
    vim.cmd("tabnew")
    self.win = vim.api.nvim_get_current_win()
  elseif self.position == "float" then
    local width = math.max(1, vim.o.columns - 4)
    local height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
    self.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 1,
      col = 2,
      width = width,
      height = height,
      style = "minimal",
      border = (chat.float or {}).border or "rounded",
      zindex = 40,
    })
  elseif self.position == "bottom" then
    vim.cmd("botright new")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(self.win, math.max(10, math.floor(vim.o.lines * chat.height)))
  elseif self.position == "right" then
    vim.cmd("botright vnew")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(self.win, math.max(42, math.floor(vim.o.columns * chat.width)))
  else
    error("pi.nvim: chat.position must be 'right', 'bottom', 'tab', or 'float'")
  end
  vim.api.nvim_win_set_buf(self.win, buf)
  style_window(self.win, "PiCanvasNormal")
  vim.wo[self.win].cursorline = false
  vim.wo[self.win].winbar = ""

  local width = vim.api.nvim_win_get_width(self.win)
  local input_win = vim.api.nvim_open_win(input_buf, false, self:_input_window_config(0, math.max(1, width - 2), 3))
  style_window(input_win, "PiInputNormal")
  vim.wo[input_win].cursorline = false
  vim.wo[input_win].spell = false
  vim.wo[input_win].winblend = 0
  vim.wo[input_win].winbar = " "

  local status_win = vim.api.nvim_open_win(status_buf, false, {
    relative = "win",
    win = self.win,
    row = 0,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 51,
  })
  style_window(status_win, "PiStatusNormal")
  vim.wo[status_win].wrap = false
  vim.wo[status_win].winbar = ""
  self.input_area:set_windows(input_win, status_win)

  self:_update_input_chrome()
  self:_sync_animation()
  sync_welcome_animation()
  if focus_input ~= false then
    self:_focus_input()
  end
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
