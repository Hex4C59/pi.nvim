local config = require("pi.config")
local renderer = require("pi.ui.render")
local highlights = require("pi.ui.highlights")
local command_menu = require("pi.ui.command_menu")
local input_area = require("pi.ui.input")

local M = {}
local Chat = {}
Chat.__index = Chat

local namespace = vim.api.nvim_create_namespace("pi.nvim")
local instances = setmetatable({}, { __mode = "v" })
local welcome_animation_timer = nil
local welcome_animation_frame = 0

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
  callback = stop_welcome_animation,
})

local function text_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      table.insert(parts, block.text or "")
    end
  end
  return table.concat(parts, "\n")
end

local function format_count(value)
  value = tonumber(value) or 0
  if value < 1000 then
    return tostring(math.floor(value))
  elseif value < 10000 then
    return ("%.1fk"):format(value / 1000)
  elseif value < 1000000 then
    return ("%dk"):format(math.floor(value / 1000 + 0.5))
  elseif value < 10000000 then
    return ("%.1fM"):format(value / 1000000)
  end
  return ("%dM"):format(math.floor(value / 1000000 + 0.5))
end

function Chat.new(root)
  highlights.setup()
  update_welcome_logo_highlights()
  local chat = setmetatable({
    root = root,
    buf = nil,
    win = nil,
    input_buf = nil,
    input_win = nil,
    command_buf = nil,
    command_win = nil,
    command_matches = {},
    command_selected = 1,
    command_first = 1,
    status_buf = nil,
    status_win = nil,
    transcript_width = nil,
    history_loaded = false,
    items = {},
    tools_by_id = {},
    tool_ranges = {},
    process_ranges = {},
    streaming_assistant = nil,
    tools_expanded = false,
    hide_thinking = true,
    process_expanded = false,
    commands = {},
    queue = { steering = {}, followUp = {} },
    render_pending = false,
    animation_frame = 0,
    animation_timer = nil,
    activity_started_at = nil,
    path = root,
    activity = "starting",
    model = "loading",
    thinking = "-",
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
  instances[root] = chat
  return chat
end

function Chat:is_open()
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and self.input_win ~= nil
    and vim.api.nvim_win_is_valid(self.input_win)
    and self.status_win ~= nil
    and vim.api.nvim_win_is_valid(self.status_win)
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
  if self:_is_active() or self.streaming_assistant then
    return true
  end
  for index = #self.items, 1, -1 do
    local item = self.items[index]
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
    local label = labels[self.activity] or self.activity:gsub("^%l", string.upper)
    return label .. " · " .. duration
  end
  return self.activity
end

function Chat:_input_frame(width)
  return self.input_area:frame(width)
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
      self:_layout()
    end)
  )
end

function Chat:close()
  self:_stop_animation()
  for _, win in ipairs({ self.command_win, self.status_win, self.input_win, self.win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  self.command_win = nil
  self.command_matches = {}
  self.status_win = nil
  self.input_win = nil
  self.win = nil
  sync_welcome_animation()
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
  self:_sync_animation()
  self:_layout()
  if was_active ~= self:_is_active() and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
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
  self:_sync_animation()
  self:_update_input_chrome()
  self:_render_status()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
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

function Chat:_ensure_command_buffer()
  return self.command_menu:ensure_buffer()
end

function Chat:_close_command_menu()
  self.command_menu:close()
end

function Chat:_render_command_menu(width, height, first)
  self.command_menu:render(width, height, first)
end

function Chat:_layout_command_menu()
  return self.command_menu:layout()
end

function Chat:_open_command_menu()
  return self.command_menu:open()
end

function Chat:_update_command_menu()
  return self.command_menu:update()
end

function Chat:_show_command_completion()
  return self.command_menu:show()
end

function Chat:_select_command(delta)
  return self.command_menu:select(delta)
end

function Chat:_accept_command_completion()
  return self.command_menu:accept()
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
    title = { { " pi ", "PiPanelTitle" } },
    title_pos = "center",
    zindex = 40,
  })
end
function Chat:_layout()
  self:_layout_main()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  if not self.status_win or not vim.api.nvim_win_is_valid(self.status_win) then
    return
  end

  local width = vim.api.nvim_win_get_width(self.win)
  local height = vim.api.nvim_win_get_height(self.win)
  local transcript_width_changed = self.transcript_width ~= width
  self.transcript_width = width
  local footer_height = 1
  local available_input = math.max(1, height - footer_height - 4)
  local input_height = math.min(self:_desired_input_height(), available_input)
  local input_row = math.max(0, height - footer_height - input_height - 2)
  local footer_row = math.max(0, height - footer_height)

  local input_config = self:_input_window_config(input_row, math.max(1, width - 4), input_height)
  vim.api.nvim_win_set_config(self.input_win, input_config)
  vim.api.nvim_win_set_config(self.status_win, {
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

  local overlay_height = input_height + footer_height + 2
  local overlay_changed = self.overlay_height ~= overlay_height
  self.overlay_height = overlay_height
  self:_render_status()
  if overlay_changed or transcript_width_changed then
    self:_render_transcript()
  end
end
function Chat:_resize_input()
  self.input_area:resize()
end
function Chat:set_input(text)
  self.input_area:set_input(text)
end
function Chat:_focus_input()
  self.input_area:focus()
end
function Chat:_ensure_input_buffer()
  return self.input_area:ensure_input_buffer()
end
function Chat:_ensure_status_buffer()
  return self.input_area:ensure_status_buffer()
end
function Chat:_ensure_buffer()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  input_area.name_buffer(self.buf, "chat", self.root)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "markdown"
  vim.bo[self.buf].modifiable = false

  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, silent = true })
  for _, key in ipairs({ "i", "a" }) do
    vim.keymap.set("n", key, function()
      self:_focus_input()
    end, { buffer = self.buf, silent = true })
  end
  vim.keymap.set("n", "<C-c>", function()
    require("pi").abort(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-l>", function()
    require("pi").select_model(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    require("pi").cycle_model(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pi").cycle_thinking_level(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-o>", function()
    self:toggle_tools()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-t>", function()
    self:toggle_thinking()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-x>", function()
    self:copy_last_assistant()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function()
    input_area.dispatch_left_mouse(self)
  end, { buffer = self.buf, silent = true })
  return self.buf
end

local function style_window(win, normal_group)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
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
  local buf = self:_ensure_buffer()
  local input_buf = self:_ensure_input_buffer()
  local status_buf = self:_ensure_status_buffer()
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
  self.input_win = vim.api.nvim_open_win(input_buf, false, self:_input_window_config(0, math.max(1, width - 4), 3))
  style_window(self.input_win, "PiInputNormal")
  vim.wo[self.input_win].cursorline = false
  vim.wo[self.input_win].spell = false
  vim.wo[self.input_win].winblend = 0
  vim.wo[self.input_win].winbar = " "

  self.status_win = vim.api.nvim_open_win(status_buf, false, {
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
  style_window(self.status_win, "PiStatusNormal")
  vim.wo[self.status_win].wrap = false
  vim.wo[self.status_win].winbar = ""

  self:_update_input_chrome()
  self:_sync_animation()
  sync_welcome_animation()
  if focus_input ~= false then
    self:_focus_input()
  end
end

function Chat:_with_modifiable(callback)
  local buf = self:_ensure_buffer()
  vim.bo[buf].modifiable = true
  callback(buf)
  vim.bo[buf].modifiable = false
end

function Chat:_clamp_transcript_view()
  if
    not self.win
    or not vim.api.nvim_win_is_valid(self.win)
    or not self.buf
    or not vim.api.nvim_buf_is_valid(self.buf)
    or vim.api.nvim_win_get_buf(self.win) ~= self.buf
  then
    return false
  end

  local clamped = false
  vim.api.nvim_win_call(self.win, function()
    local last_line = vim.api.nvim_buf_line_count(self.buf)
    if vim.fn.line("w$") ~= last_line then
      return
    end

    local position = vim.fn.screenpos(self.win, last_line, 1)
    local window_position = vim.fn.win_screenpos(self.win)
    local relative_row = position.row - window_position[1] + 1
    local view = vim.fn.winsaveview()
    local has_scrolled_origin = view.topline > 1 or (view.skipcol or 0) > 0
    if position.row > 0 and relative_row < vim.api.nvim_win_get_height(self.win) and has_scrolled_origin then
      vim.cmd("normal! Gzb")
      clamped = true
    end
  end)
  return clamped
end

function Chat:_render_transcript()
  local follow_output = true
  local previous_row = 1
  if self.win and vim.api.nvim_win_is_valid(self.win) and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    previous_row = vim.api.nvim_win_get_cursor(self.win)[1]
    follow_output = previous_row >= vim.api.nvim_buf_line_count(self.buf) - 1
  end

  local width = self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or 80
  local lines, marks, tool_ranges, process_ranges = renderer.render(self.items, {
    hide_thinking = self.hide_thinking,
    tools_expanded = self.tools_expanded,
    collapse_processes = true,
    process_expanded = self.process_expanded,
    process_active = self:_process_is_active(),
    width = width,
    welcome = {
      model = self.model,
      thinking = self.thinking,
      root = self.root,
      permission = (config.get().security or {}).mode,
    },
  })
  self.tool_ranges = tool_ranges
  self.process_ranges = process_ranges
  for _ = 1, self.overlay_height or 0 do
    table.insert(lines, "")
  end
  if #lines == 0 then
    lines = { "" }
  end

  self:_with_modifiable(function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, mark in ipairs(marks) do
      if mark.line_highlight then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row, 0, {
          line_hl_group = mark.line_highlight,
          priority = mark.priority or 90,
        })
      end
      if mark.highlight and mark.end_col > mark.start_col then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.start_col, {
          end_col = mark.end_col,
          hl_group = mark.highlight,
          priority = mark.priority or 100,
        })
      end
    end
  end)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local row = follow_output and #lines or math.min(previous_row, #lines)
    vim.api.nvim_win_set_cursor(self.win, { math.max(1, row), 0 })
  end
end

function Chat:_schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.defer_fn(function()
    self.render_pending = false
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      self:_render_transcript()
    end
  end, 25)
end

function Chat:clear()
  self.items = {}
  self.tools_by_id = {}
  self.tool_ranges = {}
  self.process_ranges = {}
  self.streaming_assistant = nil
  self:_render_transcript()
end

function Chat:add_user(text)
  table.insert(self.items, { type = "user", text = text or "" })
  self:_render_transcript()
end

function Chat:start_assistant(message)
  local item = { type = "assistant", message = message or { content = {} }, started_at = vim.uv.hrtime() }
  table.insert(self.items, item)
  self.streaming_assistant = item
  self:_render_transcript()
end

function Chat:update_assistant(message)
  if not self.streaming_assistant then
    self:start_assistant(message)
    return
  end
  self.streaming_assistant.message = message
  self:_schedule_render()
end

function Chat:end_assistant(message)
  if not self.streaming_assistant then
    self:start_assistant(message)
  else
    self.streaming_assistant.message = message
  end
  if self.streaming_assistant.started_at then
    self.streaming_assistant.duration_ms =
      math.max(1, math.floor((vim.uv.hrtime() - self.streaming_assistant.started_at) / 1000000))
  end
  self.streaming_assistant = nil
  self:_render_transcript()
end

function Chat:start_tool(id, name, args)
  local item = self.tools_by_id[id]
  if item then
    item.name = name or item.name
    item.args = args or item.args
    item.state = "pending"
  else
    item = {
      type = "tool",
      id = id,
      name = name or "tool",
      args = args or {},
      state = "pending",
      started_at = vim.uv.hrtime(),
    }
    self.tools_by_id[id] = item
    table.insert(self.items, item)
  end
  self:_render_transcript()
end

function Chat:update_tool(id, result)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.result = result
  item.state = "pending"
  self:_schedule_render()
end

function Chat:append_bash_delta(id, delta)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.bash_output = (item.bash_output or "") .. (delta or "")
  item.result = { content = { { type = "text", text = item.bash_output } } }
  self:_schedule_render()
end

function Chat:end_bash(id, data, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  data = data or {}
  local output = item.bash_output
  if not output or output == "" then
    output = data.output or ""
  end
  self:end_tool(id, {
    content = { { type = "text", text = output } },
    details = data,
  }, is_error)
end

function Chat:end_tool(id, result, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.result = result
  item.error = is_error == true
  item.state = "done"
  if item.started_at then
    item.duration_ms = math.max(1, math.floor((vim.uv.hrtime() - item.started_at) / 1000000))
  end
  self:_render_transcript()
end

function Chat:add_status(text, is_error)
  table.insert(self.items, { type = "status", text = text, error = is_error == true })
  self:_render_transcript()
end

function Chat:_tool_at_row(row)
  row = tonumber(row)
  if not row then
    return nil
  end
  for _, range in ipairs(self.tool_ranges or {}) do
    if row >= range.first and row <= range.last then
      return range.item
    end
  end
end

function Chat:_process_at_row(row)
  row = tonumber(row)
  if not row then
    return nil
  end
  for _, range in ipairs(self.process_ranges or {}) do
    if row >= range.first and row <= range.last then
      return range
    end
  end
end

function Chat:_tool_under_cursor()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or vim.api.nvim_get_current_win() ~= self.win then
    return nil
  end
  return self:_tool_at_row(vim.api.nvim_win_get_cursor(self.win)[1])
end

function Chat:_toggle_tool(item)
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
  local item = self:_tool_at_row(mouse.line)
  local process = not item and self:_process_at_row(mouse.line) or nil
  if not item and not process then
    return false
  end

  local row = math.max(1, math.min(tonumber(mouse.line) or 1, vim.api.nvim_buf_line_count(self.buf)))
  local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
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
  for _, candidate in ipairs(self.items) do
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
  for index = #self.items, 1, -1 do
    local item = self.items[index]
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
  if self.history_loaded then
    return
  end
  self.history_loaded = true
  self.items = {}
  self.tools_by_id = {}
  self.tool_ranges = {}
  self.process_ranges = {}
  for _, message in ipairs(messages or {}) do
    if message.role == "user" then
      table.insert(self.items, { type = "user", text = text_content(message.content) })
    elseif message.role == "assistant" then
      table.insert(self.items, { type = "assistant", message = message })
      for _, block in ipairs(message.content or {}) do
        if block.type == "toolCall" then
          local item = {
            type = "tool",
            id = block.id,
            name = block.name,
            args = block.arguments or {},
            state = "pending",
          }
          self.tools_by_id[block.id] = item
          table.insert(self.items, item)
        end
      end
    elseif message.role == "toolResult" then
      local item = self.tools_by_id[message.toolCallId]
      if item then
        item.result = message
        item.error = message.isError == true
        item.state = "done"
      end
    elseif message.role == "bashExecution" then
      table.insert(self.items, {
        type = "tool",
        id = "bash-" .. tostring(message.timestamp or #self.items),
        name = "bash",
        args = { command = message.command },
        result = { content = { { type = "text", text = message.output or "" } } },
        error = (message.exitCode or 0) ~= 0,
        state = "done",
      })
    end
  end
  self:_render_transcript()
end

function M.complete(findstart, base)
  return command_menu.complete(instances, findstart, base)
end

M.Chat = Chat
M.text_content = text_content
M.format_count = format_count
M.builtin_commands = command_menu.builtin_commands
return M
