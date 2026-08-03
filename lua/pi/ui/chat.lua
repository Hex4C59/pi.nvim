local config = require("pi.config")
local renderer = require("pi.ui.render")
local highlights = require("pi.ui.highlights")
local command_menu = require("pi.ui.command_menu")
local input_area = require("pi.ui.input")
local permission_panel = require("pi.ui.permission")
local widget_panel = require("pi.ui.widget")
local permission_modes = require("pi.permission_mode")
local BoundedText = require("pi.bounded_text").BoundedText
local image_data = require("pi.ui.image")
local image_backend = require("pi.ui.image_backend")
local markdown_image = require("pi.ui.markdown_image")

local M = {}
local Chat = {}
Chat.__index = Chat

local namespace = vim.api.nvim_create_namespace("pi.nvim")
local instances = setmetatable({}, { __mode = "v" })
local welcome_animation_timer = nil
local welcome_animation_frame = 0

local function slice(items, first, last)
  local result = {}
  for index = first, last do
    table.insert(result, items[index])
  end
  return result
end

local function render_result(items, opts)
  local lines, marks, tool_ranges, process_ranges, images = renderer.render(items, opts)
  return {
    lines = lines,
    marks = marks,
    tool_ranges = tool_ranges,
    process_ranges = process_ranges,
    images = images or {},
  }
end

local function merge_ranges(prefix, tail, row_offset)
  local result = vim.list_slice(prefix or {})
  for _, range in ipairs(tail or {}) do
    table.insert(
      result,
      vim.tbl_extend("force", {}, range, {
        first = range.first + row_offset,
        last = range.last + row_offset,
      })
    )
  end
  return result
end

local function merge_images(prefix, tail, row_offset)
  local result = vim.list_slice(prefix or {})
  for _, image in ipairs(tail or {}) do
    table.insert(result, vim.tbl_extend("force", {}, image, { row = image.row + row_offset }))
  end
  return result
end

local function offset_marks(marks, row_offset)
  local result = {}
  for _, mark in ipairs(marks or {}) do
    table.insert(result, vim.tbl_extend("force", {}, mark, { row = mark.row + row_offset }))
  end
  return result
end

local function effective_marks_by_row(marks)
  local rows = {}
  for _, mark in ipairs(marks) do
    if mark.line_highlight or (mark.highlight and mark.end_col > mark.start_col) then
      rows[mark.row + 1] = rows[mark.row + 1] or {}
      table.insert(rows[mark.row + 1], mark)
    end
  end
  return rows
end

local function marks_equal(left, right)
  left = left or {}
  right = right or {}
  if #left ~= #right then
    return false
  end
  for index, mark in ipairs(left) do
    local other = right[index]
    if
      mark.start_col ~= other.start_col
      or mark.end_col ~= other.end_col
      or mark.highlight ~= other.highlight
      or mark.line_highlight ~= other.line_highlight
      or mark.priority ~= other.priority
    then
      return false
    end
  end
  return true
end

local function add_marks(buf, marks, first_row, last_row, row_offset)
  row_offset = row_offset or 0
  for _, mark in ipairs(marks) do
    if mark.row >= first_row and mark.row < last_row then
      if mark.line_highlight then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row + row_offset, 0, {
          line_hl_group = mark.line_highlight,
          priority = mark.priority or 90,
        })
      end
      if mark.highlight and mark.end_col > mark.start_col then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row + row_offset, mark.start_col, {
          end_col = mark.end_col,
          hl_group = mark.highlight,
          priority = mark.priority or 100,
        })
      end
    end
  end
end

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

local function utf8_tail(text, maximum)
  if #text <= maximum then
    return text, 0
  end
  local first = #text - maximum + 1
  while first <= #text do
    local byte = text:byte(first)
    if not byte or byte < 0x80 or byte > 0xBF then
      break
    end
    first = first + 1
  end
  return text:sub(first), first - 1
end

local function utf8_head(text, maximum)
  if #text <= maximum then
    return text, 0
  end
  local boundary = maximum
  while boundary > 0 do
    local next_byte = text:byte(boundary + 1)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    boundary = boundary - 1
  end
  return text:sub(1, boundary), #text - boundary
end

local arg_key_priority = {
  path = 1,
  file_path = 1,
  command = 2,
  pattern = 3,
  query = 3,
  glob = 3,
  offset = 4,
  limit = 4,
  edits = 10,
  oldText = 11,
  newText = 11,
  old_string = 11,
  new_string = 11,
  content = 12,
}
local arg_key_order = {
  "path",
  "file_path",
  "command",
  "pattern",
  "query",
  "glob",
  "offset",
  "limit",
  "edits",
  "oldText",
  "newText",
  "old_string",
  "new_string",
  "content",
}

local function bounded_arg_keys(value, maximum)
  local keys = {}
  local seen = {}
  local overflow = false
  for _, key in ipairs(arg_key_order) do
    seen[key] = true
    if value[key] ~= nil then
      if #keys < maximum then
        table.insert(keys, key)
      else
        overflow = true
      end
    end
  end
  for key in pairs(value) do
    if not seen[key] then
      if #keys >= maximum then
        overflow = true
        break
      end
      table.insert(keys, key)
    end
  end
  table.sort(keys, function(left, right)
    local left_priority = arg_key_priority[left] or 100
    local right_priority = arg_key_priority[right] or 100
    if left_priority == right_priority then
      if type(left) == "number" and type(right) == "number" then
        return left < right
      end
      return tostring(left) < tostring(right)
    end
    return left_priority < right_priority
  end)
  return keys, overflow
end

local function limited_tool_args(args, maximum, maximum_nodes)
  local retained = 0
  local omitted = 0
  local nodes = 0
  maximum_nodes = maximum_nodes or 2048

  local function copy(value)
    if nodes >= maximum_nodes then
      omitted = omitted + 1
      return nil
    end
    nodes = nodes + 1
    if type(value) == "string" then
      local kept, removed = utf8_head(value, math.max(0, maximum - retained))
      retained = retained + #kept
      omitted = omitted + removed
      return kept
    elseif type(value) ~= "table" then
      return value
    end

    local result = {}
    local keys, overflow = bounded_arg_keys(value, math.max(0, maximum_nodes - nodes))
    if overflow then
      omitted = omitted + 1
    end
    for _, key in ipairs(keys) do
      local copied = copy(value[key])
      if copied ~= nil then
        result[key] = copied
      end
    end
    return result
  end

  return copy(type(args) == "table" and args or {}) or {}, retained, omitted
end

local function summarized_tool_args(args)
  local summary = {}
  for _, key in ipairs({ "path", "file_path", "command", "pattern", "query", "glob", "offset", "limit" }) do
    if args[key] ~= nil then
      summary[key] = args[key]
    end
  end
  return limited_tool_args(summary, 512, 32)
end

local function result_without_content(result)
  local copy = {}
  if type(result) ~= "table" then
    copy.content = {}
    return copy
  end
  for key, value in pairs(result or {}) do
    if key ~= "content" then
      copy[key] = value
    end
  end
  copy.content = {}
  return copy
end

local function details_without_output(details)
  local copy = {}
  if type(details) ~= "table" then
    return copy
  end
  for key, value in pairs(details or {}) do
    if key ~= "output" then
      copy[key] = value
    end
  end
  return copy
end

local function limited_result(result, maximum)
  local limited = { content = {} }
  local retained = 0
  local omitted = 0
  for _, block in ipairs((type(result) == "table" and result.content) or {}) do
    local remaining = math.max(0, maximum - retained)
    if block.type == "text" then
      local text = type(block.text) == "string" and block.text or ""
      local kept, removed = utf8_tail(text, remaining)
      omitted = omitted + removed
      if kept ~= "" then
        table.insert(limited.content, { type = "text", text = kept })
        retained = retained + #kept
      end
    elseif block.type == "image" then
      local payload = type(block.data) == "string" and block.data
        or type(block.source) == "table" and type(block.source.data) == "string" and block.source.data
        or ""
      if #payload <= remaining then
        table.insert(limited.content, block)
        retained = retained + #payload
      else
        omitted = omitted + #payload
        table.insert(limited.content, {
          type = "omitted",
          reason = "image_limit",
          omittedBytes = #payload,
          clientOmitted = true,
        })
      end
    end
  end
  for key, value in pairs(type(result) == "table" and result or {}) do
    if key ~= "content" then
      if type(value) == "string" then
        local kept, removed = utf8_head(value, math.max(0, maximum - retained))
        limited[key] = kept
        retained = retained + #kept
        omitted = omitted + removed
      elseif type(value) == "table" then
        local kept, kept_bytes, removed = limited_tool_args(value, math.max(0, maximum - retained), 512)
        limited[key] = kept
        retained = retained + kept_bytes
        omitted = omitted + removed
      else
        limited[key] = value
      end
    end
  end
  if omitted > 0 then
    if type(limited.details) ~= "table" then
      limited.details = {}
    end
    limited.details.clientTruncated = true
    limited.details.clientOmittedBytes = (limited.details.clientOmittedBytes or 0) + omitted
    limited.details.clientRetainedBytes = retained
  end
  return limited, retained
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
    permission_buf = nil,
    permission_win = nil,
    widget_buf = nil,
    widget_win = nil,
    permission_restore_height = nil,
    transcript_width = nil,
    history_loaded = false,
    items = {},
    next_item_id = 0,
    pending_images = {},
    tools_by_id = {},
    tool_retained_bytes = 0,
    tool_ranges = {},
    process_ranges = {},
    image_placements = {},
    image_preview_buf = nil,
    image_preview_win = nil,
    image_preview_block = nil,
    streaming_assistant = nil,
    tools_expanded = false,
    hide_thinking = true,
    process_expanded = false,
    commands = {},
    queue = { steering = {}, followUp = {} },
    render_pending = false,
    render_timer = nil,
    render_cache = nil,
    render_frame = nil,
    prepared_images_width = nil,
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
      chat:_invalidate_render_cache()
      chat:_schedule_render()
    end,
  })
  instances[root] = chat
  return chat
end

function Chat:_new_item_id(kind)
  self.next_item_id = self.next_item_id + 1
  return ("%s:%d"):format(kind or "item", self.next_item_id)
end

function Chat:_invalidate_render_cache()
  self.render_cache = nil
end

function Chat:_invalidate_cached_item(item)
  if self.render_cache and self.render_cache.items[item] then
    self:_invalidate_render_cache()
  end
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
      self.input_area:update_frame()
    end)
  )
end

function Chat:close()
  self:_stop_animation()
  self:_close_image_preview()
  if self.image_backend then
    self.image_backend:clear(self.buf)
  end
  self.permission_area:cancel_all()
  self.widget_area:close_windows()
  for _, win in ipairs({ self.command_win, self.permission_win, self.status_win, self.input_win, self.win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  self.command_win = nil
  self.command_matches = {}
  self.permission_win = nil
  self.permission_restore_height = nil
  self.status_win = nil
  self.input_win = nil
  self.win = nil
  self.transcript_width = nil
  sync_welcome_animation()
end

function Chat:destroy()
  self:close()
  if self.render_timer then
    self.render_timer:stop()
    self.render_timer:close()
    self.render_timer = nil
  end
  self.items = {}
  self.tools_by_id = {}
  self.tool_retained_bytes = 0
  self.render_cache = nil
  self.render_frame = nil
  self.pending_images = {}
  self.image_placements = {}
  self.streaming_assistant = nil
  self.widget_area:clear()
  for _, field in ipairs({ "command_buf", "permission_buf", "widget_buf", "status_buf", "input_buf", "buf" }) do
    local bufnr = self[field]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    self[field] = nil
  end
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
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
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

function Chat:_ensure_command_buffer()
  return self.command_menu:ensure_buffer()
end

function Chat:_close_command_menu()
  local visible = self.command_menu:visible()
  self.command_menu:close()
  if visible then
    self:_layout()
  end
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
  local visible = self.command_menu:update()
  self:_layout()
  return visible
end

function Chat:_show_command_completion()
  return self.command_menu:show()
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
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.b[self.buf].pi_title = self.title
    local label = ("Pi · %s · %s"):format(self.title, vim.fs.basename(self.root))
    if not pcall(vim.api.nvim_buf_set_name, self.buf, label) then
      pcall(vim.api.nvim_buf_set_name, self.buf, label .. " · " .. vim.fn.sha256(self.root):sub(1, 6))
    end
  end
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
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  if not self.status_win or not vim.api.nvim_win_is_valid(self.status_win) then
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
  local transcript_width_changed = self.transcript_width ~= width
  self.transcript_width = width
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

  local input_config = self:_input_window_config(input_row, math.max(1, width - 2), input_height)
  input_config.focusable = not permission_active
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

  local permission_height = permission_active and self.permission_area:layout(width, input_row) or 0
  self.widget_area:layout(widget_width, input_row, input_height, above_widget_height, below_widget_height)
  local overlay_height = input_height + footer_height + 2 + permission_height + widget_height
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

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = ui_group,
    buffer = self.buf,
    callback = function(event)
      if self.image_backend then
        self.image_backend:clear(event.buf)
      end
      if self.buf == event.buf then
        self.buf = nil
        self.render_frame = nil
      end
    end,
  })

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
  vim.keymap.set("n", "<CR>", function()
    local descriptor = self:_image_at_row(vim.api.nvim_win_get_cursor(self.win)[1])
    if descriptor then
      self:_open_image_preview(descriptor)
    else
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    end
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

function Chat:_close_image_preview()
  local buf = self.image_preview_buf
  local win = self.image_preview_win
  self.image_preview_buf = nil
  self.image_preview_win = nil
  self.image_preview_block = nil
  if self.image_backend and buf then
    self.image_backend:clear(buf)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

function Chat:_render_image_preview_blocks(block)
  local buf = self.image_preview_buf
  if self.image_preview_block ~= block or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local preview = image_data.preview(block)
  local lines = {}
  if preview then
    for _, preview_row in ipairs(preview.rows) do
      table.insert(lines, preview_row.text)
    end
  else
    lines = { image_data.fallback(block) }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if preview then
    for row, preview_row in ipairs(preview.rows) do
      for _, mark in ipairs(preview_row.marks) do
        vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, mark.start_col, {
          end_col = mark.end_col,
          hl_group = mark.highlight,
          priority = 150,
        })
      end
    end
  end
  vim.bo[buf].modifiable = false
end

function Chat:_open_image_preview(descriptor)
  local prepared = descriptor and image_data.prepared(descriptor.block)
  if not prepared then
    return false
  end
  self:_close_image_preview()

  local maximum_width = math.max(12, vim.o.columns - 4)
  local maximum_height = math.max(4, vim.o.lines - vim.o.cmdheight - 4)
  local block = {
    type = "image",
    mimeType = prepared.mime_type,
    path = prepared.path,
  }
  local zoom = image_data.prepare(block, maximum_width, nil, {
    max_width = maximum_width,
    max_height = maximum_height,
  })
  if not zoom then
    return false
  end

  local width = math.max(12, zoom.width)
  local height = math.max(4, zoom.height)
  local buf = vim.api.nvim_create_buf(false, true)
  local label = ("Pi Image Preview · %s"):format(vim.fs.basename(self.root))
  if not pcall(vim.api.nvim_buf_set_name, buf, label) then
    pcall(vim.api.nvim_buf_set_name, buf, label .. " · " .. vim.fn.sha256(self.root):sub(1, 6))
  end
  vim.b[buf].pi_kind = "image_preview"
  vim.b[buf].pi_root = self.root
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pi_image_preview"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = ((config.get().chat or {}).float or {}).border or "rounded",
    title = { { (" Image %dx%d "):format(prepared.pixel_width, prepared.pixel_height), "PiPanelTitle" } },
    title_pos = "center",
    zindex = 80,
  })
  style_window(win, "PiCanvasNormal")
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  self.image_preview_buf = buf
  self.image_preview_win = win
  self.image_preview_block = block

  local function close()
    self:_close_image_preview()
  end
  for _, key in ipairs({ "q", "<Esc>", "<CR>", "<LeftMouse>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, silent = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = ui_group,
    pattern = tostring(win),
    once = true,
    callback = function()
      if self.image_preview_win == win then
        self:_close_image_preview()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = ui_group,
    buffer = buf,
    once = true,
    callback = function(event)
      if self.image_preview_buf ~= event.buf then
        return
      end
      local preview_win = self.image_preview_win
      self.image_preview_buf = nil
      self.image_preview_win = nil
      self.image_preview_block = nil
      if self.image_backend then
        self.image_backend:clear(event.buf)
      end
      if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        pcall(vim.api.nvim_win_close, preview_win, true)
      end
    end,
  })

  if self.image_backend and self.image_backend:is_terminal() then
    self.image_backend:sync(buf, win, {
      {
        key = "preview:" .. zoom.key,
        content_key = zoom.key,
        block = block,
        path = zoom.path,
        row = 0,
        col = 0,
        width = zoom.width,
        height = zoom.height,
        range_height = 1,
        conceal = true,
        inline = false,
      },
    })
  else
    image_data.prepare_preview(block, function()
      self:_render_image_preview_blocks(block)
    end)
    self:_render_image_preview_blocks(block)
  end
  return true
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
  self.input_win = vim.api.nvim_open_win(input_buf, false, self:_input_window_config(0, math.max(1, width - 2), 3))
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
  for _, item in pairs(self.tools_by_id) do
    if item.bash_dirty then
      self:_materialize_bash(item)
    end
  end
  local follow_output = true
  local previous_row = 1
  if self.win and vim.api.nvim_win_is_valid(self.win) and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    previous_row = vim.api.nvim_win_get_cursor(self.win)[1]
    follow_output = previous_row >= vim.api.nvim_buf_line_count(self.buf) - 1
  end

  local width = self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or 80
  local process_active = self:_process_is_active()
  local stable_count = #self.items
  if #self.items > 0 and (process_active or self.items[#self.items].type == "user") then
    stable_count = 0
    for index = #self.items, 1, -1 do
      if self.items[index].type == "user" then
        stable_count = index - 1
        break
      end
    end
  end

  local image_terminal = self.image_backend and self.image_backend:is_terminal() or false
  local security_mode = (config.get().security or {}).mode
  local cache_key = table.concat({
    tostring(width),
    tostring(self.hide_thinking),
    tostring(self.tools_expanded),
    tostring(self.process_expanded),
    tostring(image_terminal),
    tostring(self.root),
    tostring(self.model),
    tostring(self.thinking),
    tostring(self:permission_mode() or "syncing"),
    tostring(security_mode),
  }, "\0")
  local previous_cache_count = self.render_cache and self.render_cache.count or 0
  local prepare_start = self.prepared_images_width == width and (previous_cache_count + 1) or 1
  self.prepared_images_width = width
  local backend_status = self.image_backend and self.image_backend.status and self.image_backend:status() or nil
  local prepare_preview = backend_status
    and backend_status.requested ~= "text"
    and backend_status.state ~= "probing"
    and not image_terminal
  self:_prepare_images(width, prepare_start, prepare_preview)

  local base_opts = {
    hide_thinking = self.hide_thinking,
    tools_expanded = self.tools_expanded,
    collapse_processes = true,
    process_expanded = self.process_expanded,
    image_terminal = image_terminal,
    root = self.root,
    width = width,
  }
  local prefix
  local cache_reused = false
  if self.render_cache and self.render_cache.key == cache_key and self.render_cache.count == stable_count then
    prefix = self.render_cache.result
    cache_reused = true
  else
    local prefix_opts = vim.tbl_extend("force", {}, base_opts, {
      process_active = false,
      welcome = {
        model = self.model,
        thinking = self.thinking,
        root = self.root,
        permission = self:permission_mode() or "syncing",
        security = security_mode,
      },
    })
    prefix = render_result(slice(self.items, 1, stable_count), prefix_opts)
    local cached_items = {}
    for index = 1, stable_count do
      cached_items[self.items[index]] = true
    end
    self.render_cache = {
      key = cache_key,
      count = stable_count,
      items = cached_items,
      result = prefix,
    }
  end

  local tail = nil
  if stable_count < #self.items then
    tail = render_result(
      slice(self.items, stable_count + 1, #self.items),
      vim.tbl_extend("force", {}, base_opts, {
        process_active = process_active,
      })
    )
  end

  local separator = tail and #prefix.lines > 0 and prefix.lines[#prefix.lines] ~= "" and #tail.lines > 0 and 1 or 0
  local prefix_rows = #prefix.lines
  local tail_offset = prefix_rows + separator
  local dynamic_lines = {}
  if separator == 1 then
    table.insert(dynamic_lines, "")
  end
  if tail then
    vim.list_extend(dynamic_lines, tail.lines)
  end
  for _ = 1, self.overlay_height or 0 do
    table.insert(dynamic_lines, "")
  end
  if prefix_rows == 0 and #dynamic_lines == 0 then
    dynamic_lines = { "" }
  end
  local dynamic_marks = tail and offset_marks(tail.marks, separator) or {}
  self.tool_ranges = merge_ranges(prefix.tool_ranges, tail and tail.tool_ranges, tail_offset)
  self.process_ranges = merge_ranges(prefix.process_ranges, tail and tail.process_ranges, tail_offset)
  self.image_placements = merge_images(prefix.images, tail and tail.images, tail_offset)
  local total_lines = prefix_rows + #dynamic_lines

  local dynamic_row_marks = effective_marks_by_row(dynamic_marks)
  self:_with_modifiable(function(buf)
    local old = self.render_frame
    local fast_path = cache_reused
      and old
      and old.prefix == prefix
      and old.prefix_rows == prefix_rows
      and vim.api.nvim_buf_line_count(buf) == old.total_lines
    if not fast_path then
      local lines = vim.list_slice(prefix.lines)
      vim.list_extend(lines, dynamic_lines)
      local marks = vim.list_slice(prefix.marks)
      vim.list_extend(marks, offset_marks(dynamic_marks, prefix_rows))
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      add_marks(buf, marks, 0, #lines)
      return
    end

    local prefix_count = 0
    local shared = math.min(#old.dynamic_lines, #dynamic_lines)
    while
      prefix_count < shared
      and old.dynamic_lines[prefix_count + 1] == dynamic_lines[prefix_count + 1]
      and marks_equal(old.dynamic_row_marks[prefix_count + 1], dynamic_row_marks[prefix_count + 1])
    do
      prefix_count = prefix_count + 1
    end
    local suffix_count = 0
    while
      suffix_count < shared - prefix_count
      and old.dynamic_lines[#old.dynamic_lines - suffix_count] == dynamic_lines[#dynamic_lines - suffix_count]
      and marks_equal(
        old.dynamic_row_marks[#old.dynamic_lines - suffix_count],
        dynamic_row_marks[#dynamic_lines - suffix_count]
      )
    do
      suffix_count = suffix_count + 1
    end

    local old_last = #old.dynamic_lines - suffix_count
    local new_last = #dynamic_lines - suffix_count
    if prefix_count == old_last and prefix_count == new_last then
      return
    end
    local first_row = prefix_rows + prefix_count
    vim.api.nvim_buf_clear_namespace(buf, namespace, first_row, prefix_rows + old_last)
    vim.api.nvim_buf_set_lines(
      buf,
      first_row,
      prefix_rows + old_last,
      false,
      slice(dynamic_lines, prefix_count + 1, new_last)
    )
    add_marks(buf, dynamic_marks, prefix_count, new_last, prefix_rows)
  end)
  self.render_frame = {
    prefix = prefix,
    prefix_rows = prefix_rows,
    dynamic_lines = vim.list_slice(dynamic_lines),
    dynamic_row_marks = dynamic_row_marks,
    total_lines = total_lines,
  }
  if self.image_backend then
    self.image_backend:sync(self.buf, self.win, self.image_placements)
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local row = follow_output and total_lines or math.min(previous_row, total_lines)
    vim.api.nvim_win_set_cursor(self.win, { math.max(1, row), 0 })
  end
end

function Chat:_prepare_images(width, start_index, prepare_preview)
  local seen = {}
  local function prepare(content, include_markdown)
    if type(content) ~= "table" then
      return
    end
    local function prepare_block(block)
      if block.type == "image" and not seen[block] then
        seen[block] = true
        local prepared = image_data.prepare(block, width - 6)
        if prepared and prepare_preview then
          image_data.prepare_preview(block, function()
            self:_invalidate_render_cache()
            self:_schedule_render()
          end)
        end
      end
    end
    for _, block in ipairs(content or {}) do
      prepare_block(block)
      if include_markdown and block.type == "text" then
        for _, referenced_image in ipairs(markdown_image.blocks(block, self.root)) do
          prepare_block(referenced_image)
        end
      end
    end
  end
  for index = math.max(1, start_index or 1), #self.items do
    local item = self.items[index]
    if item.type == "user" then
      prepare(item.content, false)
    elseif item.type == "assistant" then
      prepare(item.message and item.message.content, true)
    elseif item.type == "tool" then
      prepare(item.result and item.result.content, false)
    end
  end
end

function Chat:_schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  local interval = math.max(50, config.get().output.render_interval_ms)
  self.render_timer = vim.defer_fn(function()
    self.render_pending = false
    self.render_timer = nil
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      self:_render_transcript()
    end
  end, interval)
end

function Chat:clear()
  self.items = {}
  self:_invalidate_render_cache()
  self.prepared_images_width = nil
  self.next_item_id = 0
  self.tools_by_id = {}
  self.tool_retained_bytes = 0
  self:reset_permission_mode()
  self.tool_ranges = {}
  self.process_ranges = {}
  self.image_placements = {}
  self.streaming_assistant = nil
  self.pending_images = {}
  self.widget_area:clear()
  self.input_area:render_attachments()
  self:_render_transcript()
end

function Chat:add_user(text, content)
  table.insert(self.items, {
    type = "user",
    _pi_id = self:_new_item_id("user"),
    text = text or "",
    content = content,
  })
  self:_render_transcript()
end

function Chat:add_image_attachment(image)
  if type(image) ~= "table" or image.type ~= "image" then
    return false
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
  for _, image in ipairs(images or {}) do
    table.insert(self.pending_images, image)
  end
  self.input_area:render_attachments()
end

function Chat:start_assistant(message)
  local item = {
    type = "assistant",
    _pi_id = self:_new_item_id("assistant"),
    message = message or { content = {} },
    started_at = vim.uv.hrtime(),
  }
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
    self:_invalidate_cached_item(item)
    item.name = name or item.name
    item.state = "pending"
  else
    item = {
      type = "tool",
      _pi_id = self:_new_item_id("tool"),
      id = id,
      name = name or "tool",
      args = {},
      state = "pending",
      started_at = vim.uv.hrtime(),
    }
    self.tools_by_id[id] = item
    table.insert(self.items, item)
  end
  self:_set_tool_args(item, args or item.args)
  if item.name == "bash" then
    local output = config.get().output
    item.bash_buffer = BoundedText.new({
      max_bytes = output.live_max_bytes,
      max_lines = output.live_max_lines,
      max_chunks = output.max_chunks,
    })
    item.bash_dirty = false
  end
  self:_render_transcript()
end

function Chat:_set_tool_args(item, args)
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - (item.args_retained_bytes or 0))
  local limited, retained, omitted = limited_tool_args(args, config.get().output.tool_max_bytes)
  item.args = limited
  item.args_retained_bytes = retained
  item.args_omitted_bytes = omitted
  item.args_truncated = omitted > 0
  item.args_released = false
  self.tool_retained_bytes = self.tool_retained_bytes + retained
  self:_enforce_transcript_budget()
end

function Chat:_release_tool_args(item)
  if not item or (item.args_retained_bytes or 0) == 0 then
    return
  end
  self:_invalidate_cached_item(item)
  local previous = item.args_retained_bytes
  local summary, retained, omitted = summarized_tool_args(item.args or {})
  if retained >= previous then
    summary = {}
    retained = 0
  end
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - previous + retained)
  item.args = summary
  item.args_retained_bytes = retained
  item.args_omitted_bytes = (item.args_omitted_bytes or 0) + omitted + math.max(0, previous - retained)
  item.args_truncated = true
  item.args_released = true
end

function Chat:_release_tool_output(item)
  if not item or (item.retained_bytes or 0) == 0 then
    return
  end
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - item.retained_bytes)
  item.retained_bytes = 0
  item.result = result_without_content(item.result)
  item.output_released = true
end

function Chat:_enforce_transcript_budget()
  local maximum = config.get().output.transcript_max_bytes
  if self.tool_retained_bytes <= maximum then
    return
  end
  for _, item in ipairs(self.items) do
    if self.tool_retained_bytes <= maximum then
      break
    end
    if item.type == "tool" and item.state == "done" and not item.output_released then
      self:_release_tool_output(item)
    end
  end
  for _, item in ipairs(self.items) do
    if self.tool_retained_bytes <= maximum then
      break
    end
    if item.type == "tool" and not item.args_released then
      self:_release_tool_args(item)
    end
  end
  for _, item in ipairs(self.items) do
    if self.tool_retained_bytes <= maximum then
      break
    end
    if item.type == "tool" and (item.args_retained_bytes or 0) > 0 then
      local released = item.args_retained_bytes
      self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - released)
      item.args = {}
      item.args_retained_bytes = 0
      item.args_omitted_bytes = (item.args_omitted_bytes or 0) + released
      item.args_truncated = true
      item.args_released = true
    end
  end
end

function Chat:_set_tool_result(item, result)
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - (item.retained_bytes or 0))
  local remaining = math.max(0, config.get().output.tool_max_bytes - (item.args_retained_bytes or 0))
  local limited, retained = limited_result(result or {}, remaining)
  item.result = limited
  item.retained_bytes = retained
  item.output_released = false
  self.tool_retained_bytes = self.tool_retained_bytes + retained
  self:_enforce_transcript_budget()
end

function Chat:_materialize_bash(item)
  if not item.bash_buffer then
    return
  end
  local stats = item.bash_buffer:stats()
  local details = {}
  details = details_without_output(item.bash_details)
  details.clientTruncated = stats.truncated
  details.clientOmittedBytes = stats.omitted_bytes
  details.clientOmittedLines = stats.omitted_lines
  details.clientRetainedBytes = stats.retained_bytes
  self:_set_tool_result(item, {
    content = { { type = "text", text = item.bash_buffer:text() } },
    details = details,
  })
  item.bash_dirty = false
end

function Chat:update_tool(id, result)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.state = "pending"
  self:_set_tool_result(item, result)
  self:_schedule_render()
end

function Chat:append_bash_delta(id, delta)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  if not item.bash_buffer or type(delta) ~= "string" or delta == "" then
    return
  end
  item.bash_buffer:append(delta)
  item.bash_dirty = true
  self:_schedule_render()
end

function Chat:end_bash(id, data, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  data = data or {}
  local stats = item.bash_buffer and item.bash_buffer:stats() or { retained_bytes = 0, omitted_bytes = 0 }
  if item.bash_buffer and stats.retained_bytes == 0 and stats.omitted_bytes == 0 then
    item.bash_buffer:append(type(data.output) == "string" and data.output or "")
  end
  item.bash_details = data
  item.bash_dirty = true
  self:_materialize_bash(item)
  item.bash_buffer = nil
  item.bash_details = nil
  self:end_tool(id, item.result, is_error)
end

function Chat:end_tool(id, result, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.error = is_error == true
  item.state = "done"
  item.bash_buffer = nil
  item.bash_details = nil
  item.bash_dirty = false
  self:_set_tool_result(item, result)
  if item.started_at then
    item.duration_ms = math.max(1, math.floor((vim.uv.hrtime() - item.started_at) / 1000000))
  end
  self:_render_transcript()
end

function Chat:add_status(text, is_error)
  table.insert(self.items, {
    type = "status",
    _pi_id = self:_new_item_id("status"),
    text = text,
    error = is_error == true,
  })
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

function Chat:_image_at_row(row)
  row = tonumber(row)
  if not row then
    return nil
  end
  for index = #(self.image_placements or {}), 1, -1 do
    local descriptor = self.image_placements[index]
    local first = descriptor.row + 1
    local last = first + (descriptor.range_height or descriptor.height or 1) - 1
    if row >= first and row <= last then
      return descriptor
    end
  end
end

function Chat:_image_at_mouse(mouse)
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or not mouse or tonumber(mouse.winid) ~= self.win then
    return nil
  end
  local screen_row = tonumber(mouse.screenrow)
  local screen_col = tonumber(mouse.screencol)
  if screen_row and screen_col then
    for index = #(self.image_placements or {}), 1, -1 do
      local descriptor = self.image_placements[index]
      local position = vim.fn.screenpos(self.win, descriptor.row + 1, descriptor.col + 1)
      if
        position.row > 0
        and screen_row >= position.row
        and screen_row < position.row + descriptor.height
        and screen_col >= position.col
        and screen_col < position.col + descriptor.width
      then
        return descriptor
      end
    end
  end
  return self:_image_at_row(mouse.line)
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
  self:_invalidate_render_cache()
  self.prepared_images_width = nil
  self.items = {}
  self.next_item_id = 0
  self.tools_by_id = {}
  self.tool_retained_bytes = 0
  self.tool_ranges = {}
  self.process_ranges = {}
  for _, message in ipairs(messages or {}) do
    if message.role == "user" then
      table.insert(self.items, {
        type = "user",
        _pi_id = self:_new_item_id("history-user"),
        text = text_content(message.content),
        content = message.content,
      })
    elseif message.role == "assistant" then
      table.insert(self.items, {
        type = "assistant",
        _pi_id = self:_new_item_id("history-assistant"),
        message = message,
      })
      for _, block in ipairs(message.content or {}) do
        if block.type == "toolCall" then
          local item = {
            type = "tool",
            _pi_id = self:_new_item_id("history-tool"),
            id = block.id,
            name = block.name,
            args = {},
            state = "pending",
          }
          self.tools_by_id[block.id] = item
          table.insert(self.items, item)
          self:_set_tool_args(item, block.arguments or {})
        end
      end
    elseif message.role == "toolResult" then
      local item = self.tools_by_id[message.toolCallId]
      if item then
        item.error = message.isError == true
        item.state = "done"
        self:_set_tool_result(item, message)
      end
    elseif message.role == "bashExecution" then
      local item = {
        type = "tool",
        _pi_id = self:_new_item_id("history-bash"),
        id = "bash-" .. tostring(message.timestamp or #self.items),
        name = "bash",
        args = {},
        error = (message.exitCode or 0) ~= 0,
        state = "done",
      }
      self.tools_by_id[item.id] = item
      table.insert(self.items, item)
      self:_set_tool_args(item, { command = message.command })
      self:_set_tool_result(item, {
        content = { { type = "text", text = message.output or "" } },
        details = details_without_output(message),
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
