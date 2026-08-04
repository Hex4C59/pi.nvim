-- Prompt input and status-bar area. InputArea owns its buffers and windows;
-- Chat only coordinates their placement with the transcript and widgets.

local M = {}
local attachment_namespace = vim.api.nvim_create_namespace("pi.nvim.input.attachments")
local attachment_marker_prefix = string.char(0xee, 0x80)
local attachment_marker_bytes = 3
local attachment_slot_limit = 32

local function attachment_marker(id)
  if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > attachment_slot_limit then
    return nil
  end
  return attachment_marker_prefix .. string.char(0x7f + id)
end

local function marker_id_at(line, column)
  if line:sub(column + 1, column + 2) ~= attachment_marker_prefix then
    return nil
  end
  local suffix = line:byte(column + 3)
  if not suffix or suffix < 0x80 or suffix > 0x9f then
    return nil
  end
  return suffix - 0x7f
end

local function name_buffer(buf, kind, root)
  local titles = {
    chat = "Pi Chat",
    commands = "Pi Commands",
    ["inline-menu"] = "Pi Menu",
    ["inline-query"] = "Pi Menu Query",
    prompt = "Pi",
    status = "Pi Status",
  }
  local label = ("%s · %s"):format(titles[kind] or "Pi", vim.fs.basename(root))
  local ok = pcall(vim.api.nvim_buf_set_name, buf, label)
  if not ok then
    vim.api.nvim_buf_set_name(buf, label .. " · " .. vim.fn.sha256(root):sub(1, 6))
  end
  vim.b[buf].pi_kind = kind
  vim.b[buf].pi_root = root
end

local function isolate_input_completion(buf)
  vim.b[buf].completion = false
  vim.bo[buf].complete = ""
  vim.bo[buf].completefunc = ""
  vim.bo[buf].omnifunc = ""
  vim.bo[buf].tagfunc = ""
  vim.bo[buf].dictionary = ""
  vim.bo[buf].thesaurus = ""
  vim.bo[buf].filetype = "pi_prompt"

  local cmp = package.loaded.cmp
  if type(cmp) == "table" and cmp.setup and cmp.setup.buffer then
    pcall(vim.api.nvim_buf_call, buf, function()
      cmp.setup.buffer({ enabled = false })
    end)
  end
end

local function dispatch_left_mouse(action)
  if not action(vim.fn.getmousepos()) then
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "n", false)
  end
end

local function truncate_display(text, width)
  if width <= 0 then
    return ""
  end
  if vim.api.nvim_strwidth(text) <= width then
    return text
  end
  if width <= 3 then
    return string.rep(".", width)
  end

  local target = width - 3
  local chars = vim.fn.strchars(text)
  local result = ""
  for index = 0, chars - 1 do
    local candidate = result .. vim.fn.strcharpart(text, index, 1)
    if vim.api.nvim_strwidth(candidate) > target then
      break
    end
    result = candidate
  end
  return result .. "..."
end

local function compose_line(left, right, width)
  width = math.max(width, 1)
  right = truncate_display(right, math.max(0, math.floor(width * 0.48)))
  local right_width = vim.api.nvim_strwidth(right)
  left = truncate_display(left, math.max(0, width - right_width - 1))
  local gap = math.max(1, width - vim.api.nvim_strwidth(left) - right_width)
  return left .. string.rep(" ", gap) .. right, #left + gap
end

local function append_chunk(chunks, text, highlight)
  if text == "" then
    return
  end
  local previous = chunks[#chunks]
  if previous and previous[2] == highlight then
    previous[1] = previous[1] .. text
  else
    table.insert(chunks, { text, highlight })
  end
end

local function format_percent(value)
  value = tonumber(value)
  if not value then
    return nil
  end
  return ("%.1f"):format(value):gsub("%.0$", "") .. "%"
end

local status_padding = "  "
local permission_highlights = {
  manual = "PiStatusPermissionManual",
  acceptEdits = "PiStatusPermissionAcceptEdits",
  auto = "PiStatusPermissionAuto",
  plan = "PiStatusPermissionPlan",
}

local function permission_highlight(state)
  return permission_highlights[state.permission_mode] or "PiStatusPermission"
end

local InputArea = {}
InputArea.__index = InputArea

local function input_border(border_highlight, corner_highlight)
  return {
    { "┌", corner_highlight },
    { "─", border_highlight },
    { "┐", corner_highlight },
    { "│", border_highlight },
    { "┘", corner_highlight },
    { "─", border_highlight },
    { "└", corner_highlight },
    { "│", border_highlight },
  }
end

function InputArea.new(deps)
  local self = setmetatable({
    root = deps.root,
    namespace = deps.namespace,
    ui_group = deps.ui_group,
    state_provider = deps.state,
    main_window = deps.main_window,
    actions = deps.actions,
    input_height = nil,
    input_buf = nil,
    input_win = nil,
    status_buf = nil,
    status_win = nil,
    clipboard = deps.clipboard or require("pi.clipboard"),
    insert_guard_generation = 0,
    internal_change = 0,
    selected_attachment_index = nil,
  }, InputArea)
  return self
end

function InputArea:frame(width)
  local state = self.state_provider()
  width = math.max(1, math.floor(width or 1))
  local active = state.active
  local base_highlight = state.activity == "error" and "PiInputBorderError"
    or active and "PiInputBorderMuted"
    or "PiInputBorder"
  local corner_highlight = state.activity == "error" and "PiInputCornerError"
    or active and "PiInputCornerMuted"
    or "PiInputCorner"
  local cell_highlights = {}

  if active and width > 1 then
    local travel = math.max(1, math.floor((width - 1) / 2))
    local period = travel * 2
    local step = (state.animation_frame or 0) * 2 % period
    local offset = step > travel and period - step or step
    local left = 1 + offset
    local right = width - offset
    for index = 1, width do
      local distance = math.min(math.abs(index - left), math.abs(index - right))
      cell_highlights[index] = distance <= 1 and "PiInputBorderPulse"
        or distance <= 3 and "PiInputBorderTrail"
        or base_highlight
    end
  else
    for index = 1, width do
      cell_highlights[index] = base_highlight
    end
  end

  local function line_chunks(first, last, character)
    local chunks = {}
    for index = first, last do
      append_chunk(chunks, character, cell_highlights[index])
    end
    return chunks
  end

  local top = line_chunks(1, width, "─")
  local label = active and (" " .. state.activity_text .. " ") or state.activity == "error" and " Error " or nil
  if not label then
    return top, line_chunks(1, width, "─"), base_highlight, corner_highlight
  end

  label = truncate_display(label, width)
  local label_width = vim.api.nvim_strwidth(label)
  local left_width = math.floor((width - label_width) / 2)
  local bottom = line_chunks(1, left_width, "─")
  append_chunk(bottom, label, state.activity == "error" and "PiInputBorderError" or "PiInputActivity")
  for index = left_width + label_width + 1, width do
    append_chunk(bottom, "─", cell_highlights[index])
  end
  return top, bottom, base_highlight, corner_highlight
end

function InputArea:window_config(row, width, height)
  local top, bottom, border_highlight, corner_highlight = self:frame(width)
  return {
    relative = "win",
    win = self.main_window(),
    row = row,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = input_border(border_highlight, corner_highlight),
    title = top,
    title_pos = "center",
    footer = bottom,
    footer_pos = "center",
    zindex = 50,
  }
end

function InputArea:update_frame()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  local width = vim.api.nvim_win_get_width(self.input_win)
  local top, bottom, border_highlight, corner_highlight = self:frame(width)
  vim.api.nvim_win_set_config(self.input_win, {
    border = input_border(border_highlight, corner_highlight),
    title = top,
    title_pos = "center",
    footer = bottom,
    footer_pos = "center",
  })
end

function InputArea:update_chrome()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  vim.wo[self.input_win].winbar = " "
  vim.wo[self.input_win].winhighlight = table.concat({
    "Normal:PiInputNormal",
    "NormalNC:PiInputNormal",
    "EndOfBuffer:PiInputNormal",
    "CursorLine:PiInputNormal",
    "Cursor:PiInputCursor",
    "CursorIM:PiInputCursor",
    "lCursor:PiInputCursor",
    "WinBar:PiInputNormal",
    "WinBarNC:PiInputNormal",
    "WinSeparator:PiPanelBorder",
    "FloatBorder:PiInputBorder",
  }, ",")
  self.actions.layout()
end

function InputArea:status_text(width)
  local state = self.state_provider()
  local context_usage = state.stats.contextUsage or {}
  local steering = #(state.queue.steering or {})
  local follow_up = #(state.queue.followUp or {})
  local right = "context " .. (format_percent(context_usage.percent) or "--")
  if steering > 0 or follow_up > 0 then
    local queued = {}
    if steering > 0 then
      table.insert(queued, ("steer %d"):format(steering))
    end
    if follow_up > 0 then
      table.insert(queued, ("next %d"):format(follow_up))
    end
    right = table.concat(queued, " · ")
  end

  local content_width = math.max(1, width - vim.api.nvim_strwidth(status_padding) * 2)
  local permission = state.permission_mode_label
  local compact = content_width < 60
  local left = compact and permission or (state.model .. " · " .. state.thinking)
  if not compact then
    right = permission .. " · " .. right
  end
  local line, right_start = compose_line(left, right, content_width)
  return { status_padding .. line }, { #status_padding + right_start }
end

function InputArea:render_status()
  local state = self.state_provider()
  if not self.status_buf or not vim.api.nvim_buf_is_valid(self.status_buf) then
    return
  end
  local width = self.status_win
      and vim.api.nvim_win_is_valid(self.status_win)
      and vim.api.nvim_win_get_width(self.status_win)
    or 80
  local lines, right_starts = self:status_text(width)
  vim.bo[self.status_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.status_buf, 0, -1, false, lines)
  vim.bo[self.status_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.status_buf, self.namespace, 0, -1)

  local function highlight(row, start_col, end_col, group, priority)
    if end_col <= start_col then
      return
    end
    vim.api.nvim_buf_set_extmark(self.status_buf, self.namespace, row, start_col, {
      end_col = end_col,
      hl_group = group,
      priority = priority or 100,
    })
  end

  local content_width = math.max(1, width - vim.api.nvim_strwidth(status_padding) * 2)
  local compact = content_width < 60
  local permission_label = state.permission_mode_label
  local permission_group = permission_highlight(state)
  if compact then
    local permission_start = lines[1]:find(permission_label, #status_padding + 1, true)
    if permission_start then
      highlight(0, permission_start - 1, permission_start - 1 + #permission_label, permission_group, 150)
    end
  else
    highlight(0, #status_padding, math.min(right_starts[1], #lines[1]), "PiStatusModel")
    local thinking_start = lines[1]:find(state.thinking, #status_padding + 1, true)
    if thinking_start then
      highlight(0, thinking_start - 1, thinking_start - 1 + #state.thinking, "PiStatusThinking", 130)
    end
    local permission_start = lines[1]:find(permission_label, right_starts[1] + 1, true)
    if permission_start then
      highlight(0, permission_start - 1, permission_start - 1 + #permission_label, permission_group, 150)
    end
  end

  local right_highlight = "PiStatusContext"
  if #(state.queue.steering or {}) > 0 or #(state.queue.followUp or {}) > 0 then
    right_highlight = "PiStatusWorking"
  else
    local percent = tonumber((state.stats.contextUsage or {}).percent)
    if percent and percent > 90 then
      right_highlight = "PiStatusError"
    elseif percent and percent > 70 then
      right_highlight = "PiStatusWarning"
    end
  end
  highlight(0, math.min(right_starts[1], #lines[1]), #lines[1], right_highlight, 140)
end

function InputArea:desired_input_height()
  local config = require("pi.config")
  local maximum = math.max(3, config.get().chat.max_input_height or 8)
  local width = self.input_win
      and vim.api.nvim_win_is_valid(self.input_win)
      and vim.api.nvim_win_get_width(self.input_win)
    or nil
  local display_lines = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)) do
    local line_width = vim.api.nvim_strwidth(line)
    display_lines = display_lines + (width and math.max(1, math.ceil(line_width / math.max(1, width))) or 1)
  end
  return math.max(3, math.min(display_lines + 2, maximum))
end

function InputArea:resize()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  local desired_height = self:desired_input_height()
  if self.input_height == desired_height then
    return
  end
  self.input_height = desired_height
  self.actions.layout()
end

function InputArea:set_input(text)
  self.actions.close_command_menu()
  local buf = self:ensure_input_buffer()
  self.selected_attachment_index = nil
  local suffix = table.concat(vim.tbl_map(attachment_marker, self:_attachment_ids()))
  self.internal_change = self.internal_change + 1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text or "") .. suffix, "\n", { plain = true }))
  self.internal_change = self.internal_change - 1
  self:resize()
  self:render_attachments()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    self:focus()
    local last = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    vim.api.nvim_win_set_cursor(self.input_win, { last, #line })
  end
end

function InputArea:_attachment_ids()
  local ids = self.state_provider().attachment_ids
  return type(ids) == "table" and ids or {}
end

function InputArea:_pending_image_count()
  return #self:_attachment_ids()
end

function InputArea:_attachment_positions(include_unknown)
  local active = {}
  for _, id in ipairs(self:_attachment_ids()) do
    active[id] = true
  end
  local positions = {}
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return positions
  end
  for row, line in ipairs(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)) do
    local column = 0
    while column <= #line - attachment_marker_bytes do
      local id = marker_id_at(line, column)
      if id then
        if include_unknown or active[id] then
          table.insert(positions, { id = id, row = row, col = column })
        end
        column = column + attachment_marker_bytes
      else
        column = column + 1
      end
    end
  end
  return positions
end

function InputArea:_position_for_attachment(index)
  local id = self:_attachment_ids()[index]
  if not id then
    return nil
  end
  for _, position in ipairs(self:_attachment_positions()) do
    if position.id == id then
      return position
    end
  end
  return nil
end

function InputArea:_clear_attachment_selection(redraw)
  if self.selected_attachment_index == nil then
    return false
  end
  self.selected_attachment_index = nil
  if redraw ~= false then
    self:render_attachments()
  end
  return true
end

function InputArea:_cursor_position()
  if
    not self.input_buf
    or not vim.api.nvim_buf_is_valid(self.input_buf)
    or not self.input_win
    or not vim.api.nvim_win_is_valid(self.input_win)
  then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(self.input_win)
  return { row = cursor[1], col = cursor[2] }
end

function InputArea:_attachment_at_cursor(before)
  local cursor = self:_cursor_position()
  if not cursor then
    return nil
  end
  for index, position in ipairs(self:_attachment_positions()) do
    local column = before and position.col or position.col + attachment_marker_bytes
    if position.row == cursor.row and column == cursor.col then
      return index
    end
  end
  return nil
end

function InputArea:_select_attachment(index)
  local count = self:_pending_image_count()
  if type(index) ~= "number" or index < 1 or index > count then
    return false
  end
  local position = self:_position_for_attachment(index)
  if not position then
    return false
  end
  self.selected_attachment_index = math.floor(index)
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_win_set_cursor(self.input_win, { position.row, position.col + attachment_marker_bytes })
  end
  self.actions.close_command_menu()
  self:render_attachments()
  return true
end

function InputArea:_delete_selected_attachment(backward)
  local index = self.selected_attachment_index
  if not index then
    return false
  end
  local id = self:_attachment_ids()[index]
  local removed = id and self.actions.remove_image_attachment(id)
  if not removed then
    self:render_attachments()
    return true
  end

  local count = self:_pending_image_count()
  local next_index
  if backward then
    next_index = index > 1 and index - 1 or nil
  elseif count > 0 then
    next_index = math.min(index, count)
  end
  self.selected_attachment_index = next_index
  if next_index then
    self:_select_attachment(next_index)
  else
    self:render_attachments()
  end
  return true
end

function InputArea:render_attachments()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.input_buf, attachment_namespace, 0, -1)
  local ids = self:_attachment_ids()
  local count = #ids
  if count == 0 then
    self.selected_attachment_index = nil
    return
  end
  if self.selected_attachment_index and self.selected_attachment_index > count then
    self.selected_attachment_index = nil
  end
  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local index_by_id = {}
  for index, id in ipairs(ids) do
    index_by_id[id] = index
  end
  for _, position in ipairs(self:_attachment_positions()) do
    local index = index_by_id[position.id]
    local line = lines[position.row] or ""
    local chunks = {}
    if position.col > 0 then
      table.insert(chunks, { " ", "PiInputNormal" })
    end
    table.insert(chunks, {
      count == 1 and "[1 image attached]" or ("[image %d]"):format(index),
      self.selected_attachment_index == index and "PiInputAttachmentSelected" or "PiInputAttachment",
    })
    if
      position.col + attachment_marker_bytes < #line
      and not marker_id_at(line, position.col + attachment_marker_bytes)
    then
      table.insert(chunks, { " ", "PiInputNormal" })
    end
    vim.api.nvim_buf_set_extmark(self.input_buf, attachment_namespace, position.row - 1, position.col, {
      end_col = position.col + attachment_marker_bytes,
      conceal = "",
      virt_text = chunks,
      virt_text_pos = "inline",
      priority = 120,
    })
  end
end

function InputArea:_sync_attachment_markers()
  if self.internal_change > 0 then
    return
  end
  local active = {}
  for _, id in ipairs(self:_attachment_ids()) do
    active[id] = true
  end
  local seen = {}
  local ordered = {}
  local invalid = {}
  for _, position in ipairs(self:_attachment_positions(true)) do
    if active[position.id] and not seen[position.id] then
      seen[position.id] = true
      table.insert(ordered, position.id)
    else
      table.insert(invalid, position)
    end
  end
  if #invalid > 0 then
    self.internal_change = self.internal_change + 1
    for index = #invalid, 1, -1 do
      local position = invalid[index]
      vim.api.nvim_buf_set_text(
        self.input_buf,
        position.row - 1,
        position.col,
        position.row - 1,
        position.col + attachment_marker_bytes,
        { "" }
      )
    end
    self.internal_change = self.internal_change - 1
  end
  self.actions.sync_image_attachments(ordered)
end

function InputArea:insert_attachment(id, cursor)
  local marker = attachment_marker(id)
  if not marker then
    return false
  end
  local buf = self:ensure_input_buffer()
  cursor = cursor or self:_cursor_position()
  if not cursor then
    local row = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    cursor = { row = row, col = #line }
  end
  local line = vim.api.nvim_buf_get_lines(buf, cursor.row - 1, cursor.row, false)[1] or ""
  cursor.col = math.max(0, math.min(cursor.col, #line))
  self.internal_change = self.internal_change + 1
  vim.api.nvim_buf_set_text(buf, cursor.row - 1, cursor.col, cursor.row - 1, cursor.col, { marker })
  self.internal_change = self.internal_change - 1
  self:_sync_attachment_markers()
  self:resize()
  self:render_attachments()
  for index, candidate in ipairs(self:_attachment_ids()) do
    if candidate == id then
      self:_select_attachment(index)
      break
    end
  end
  return true
end

function InputArea:remove_attachment(id)
  local positions = {}
  for _, position in ipairs(self:_attachment_positions(true)) do
    if position.id == id then
      table.insert(positions, position)
    end
  end
  if #positions == 0 then
    return false
  end
  self.internal_change = self.internal_change + 1
  for index = #positions, 1, -1 do
    local position = positions[index]
    vim.api.nvim_buf_set_text(
      self.input_buf,
      position.row - 1,
      position.col,
      position.row - 1,
      position.col + attachment_marker_bytes,
      { "" }
    )
  end
  self.internal_change = self.internal_change - 1
  self:resize()
  self:render_attachments()
  return true
end

function InputArea:content_parts()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return {}
  end
  local raw = table.concat(vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false), "\n")
  local active = {}
  for _, id in ipairs(self:_attachment_ids()) do
    active[id] = true
  end
  local parts = {}
  local text_start = 1
  local column = 0
  while column <= #raw - attachment_marker_bytes do
    local id = marker_id_at(raw, column)
    if id and active[id] then
      if column + 1 > text_start then
        table.insert(parts, { type = "text", text = raw:sub(text_start, column) })
      end
      table.insert(parts, { type = "attachment", id = id })
      column = column + attachment_marker_bytes
      text_start = column + 1
    else
      column = column + 1
    end
  end
  if text_start <= #raw then
    table.insert(parts, { type = "text", text = raw:sub(text_start) })
  end

  for _, part in ipairs(parts) do
    if part.type == "text" then
      part.text = part.text:gsub("^%s+", "")
      break
    end
  end
  for index = #parts, 1, -1 do
    if parts[index].type == "text" then
      parts[index].text = parts[index].text:gsub("%s+$", "")
      break
    end
  end
  local compact = {}
  for _, part in ipairs(parts) do
    if part.type ~= "text" or part.text ~= "" then
      local previous = compact[#compact]
      if previous and previous.type == "text" and part.type == "text" then
        previous.text = previous.text .. part.text
      else
        table.insert(compact, part)
      end
    end
  end
  return compact
end

local function raw_from_parts(parts)
  local chunks = {}
  for _, part in ipairs(parts or {}) do
    if part.type == "text" then
      table.insert(chunks, part.text or "")
    elseif part.type == "attachment" then
      table.insert(chunks, attachment_marker(part.id) or "")
    end
  end
  return table.concat(chunks)
end

function InputArea:restore_draft(parts)
  local buf = self:ensure_input_buffer()
  local current = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local restored = raw_from_parts(parts)
  if current ~= "" then
    restored = restored .. "\n" .. current
  end
  self.selected_attachment_index = nil
  self.internal_change = self.internal_change + 1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(restored, "\n", { plain = true }))
  self.internal_change = self.internal_change - 1
  self:_sync_attachment_markers()
  self:resize()
  self:render_attachments()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    local row = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    vim.api.nvim_win_set_cursor(self.input_win, { row, #line })
  end
end

function InputArea:focus()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  vim.api.nvim_set_current_win(self.input_win)
  self:_start_insert()
end

function InputArea:_start_insert()
  vim.cmd("startinsert")
end

function InputArea:_schedule_insert_guard()
  self.insert_guard_generation = self.insert_guard_generation + 1
  local generation = self.insert_guard_generation
  local input_buf = self.input_buf
  local input_win = self.input_win
  vim.schedule(function()
    if generation ~= self.insert_guard_generation then
      return
    end
    if self.input_buf ~= input_buf or not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
      return
    end
    if self.input_win ~= input_win or not input_win or not vim.api.nvim_win_is_valid(input_win) then
      return
    end
    if vim.api.nvim_get_current_win() ~= input_win or vim.api.nvim_get_current_buf() ~= input_buf then
      return
    end
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
      self:_start_insert()
    end
  end)
end

function InputArea:_insert_text_at_cursor(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return false
  end
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return false
  end
  self:_clear_attachment_selection(false)
  local cursor = vim.api.nvim_win_get_cursor(self.input_win)
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  vim.api.nvim_buf_set_text(self.input_buf, cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2], lines)
  if #lines == 1 then
    vim.api.nvim_win_set_cursor(self.input_win, { cursor[1], cursor[2] + #lines[1] })
  else
    vim.api.nvim_win_set_cursor(self.input_win, { cursor[1] + #lines - 1, #lines[#lines] })
  end
  self:resize()
  self:render_attachments()
  return true
end

function InputArea:_paste_clipboard(fallback)
  local image_ok, image, image_err = pcall(self.clipboard.read_image)
  if not image_ok then
    image_err = image
    image = nil
  end
  if image then
    local added, attachment_err = self.actions.add_image_attachment(image, self:_cursor_position())
    if not added and attachment_err then
      vim.notify(attachment_err, vim.log.levels.WARN, { title = "Pi clipboard" })
    end
    return added == true
  end
  if image_err then
    vim.notify(image_err, vim.log.levels.WARN, { title = "Pi clipboard" })
  end

  local text_ok, text = pcall(self.clipboard.read_text)
  if not text_ok then
    vim.notify(text, vim.log.levels.WARN, { title = "Pi clipboard" })
    text = nil
  end
  if text then
    return self:_insert_text_at_cursor(text)
  end
  if fallback then
    vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "n", false)
  end
  return false
end

function InputArea:paste_at_mouse(mouse)
  mouse = mouse or vim.fn.getmousepos()
  if
    not self.input_buf
    or not vim.api.nvim_buf_is_valid(self.input_buf)
    or not self.input_win
    or not vim.api.nvim_win_is_valid(self.input_win)
    or tonumber(mouse.winid) ~= self.input_win
    or vim.api.nvim_win_get_buf(self.input_win) ~= self.input_buf
  then
    return false
  end

  local row = tonumber(mouse.line)
  local column = tonumber(mouse.column)
  if not row or not column then
    return false
  end
  row = math.max(1, math.min(row, vim.api.nvim_buf_line_count(self.input_buf)))
  local line = vim.api.nvim_buf_get_lines(self.input_buf, row - 1, row, false)[1] or ""
  column = math.max(0, math.min(column - 1, #line))
  self:_clear_attachment_selection()
  vim.api.nvim_set_current_win(self.input_win)
  vim.api.nvim_win_set_cursor(self.input_win, { row, column })
  local pasted = self:_paste_clipboard(false)
  self:_start_insert()
  return pasted
end

function InputArea:ensure_input_buffer()
  if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
    isolate_input_completion(self.input_buf)
    return self.input_buf
  end

  self.input_buf = vim.api.nvim_create_buf(false, true)
  local input_buf = self.input_buf
  name_buffer(input_buf, "prompt", self.root)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].bufhidden = "hide"
  vim.bo[input_buf].swapfile = false
  isolate_input_completion(input_buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.ui_group,
    buffer = input_buf,
    callback = function(event)
      self:_clear_attachment_selection(false)
      self:_sync_attachment_markers()
      self:resize()
      self:render_attachments()
      if event.event == "TextChangedI" then
        vim.schedule(function()
          if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
            self.actions.update_command_menu()
          end
        end)
      else
        self.actions.close_command_menu()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = self.ui_group,
    buffer = input_buf,
    callback = function()
      self.actions.close_command_menu()
      self:_clear_attachment_selection()
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = self.ui_group,
    buffer = input_buf,
    callback = function()
      self.actions.close_command_menu()
      self:_schedule_insert_guard()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = self.ui_group,
    buffer = input_buf,
    callback = function()
      self:_schedule_insert_guard()
    end,
  })

  local function submit(behavior)
    local parts = self:content_parts()
    if #parts == 0 then
      return
    end
    self:_clear_attachment_selection(false)
    local submission = self.actions.take_prompt_draft(parts)
    if not submission then
      return
    end
    self.actions.close_command_menu()
    self.internal_change = self.internal_change + 1
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    self.internal_change = self.internal_change - 1
    self:resize()
    vim.api.nvim_win_set_cursor(self.input_win, { 1, 0 })
    self.actions.submit(submission.message, behavior, submission.images, submission.content, submission.draft)
  end

  local function feed(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
  end

  vim.keymap.set("n", "<CR>", function()
    submit(nil)
  end, { buffer = input_buf, silent = true, desc = "Submit Pi prompt" })
  vim.keymap.set("i", "<CR>", function()
    if self.actions.accept_command_completion() then
      return
    end
    submit(nil)
  end, { buffer = input_buf, silent = true, desc = "Accept command or submit Pi prompt" })
  vim.keymap.set({ "n", "i" }, "<M-CR>", function()
    submit("followUp")
  end, { buffer = input_buf, silent = true, desc = "Queue Pi follow-up" })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = input_buf, silent = true, desc = "Insert prompt line" })
  vim.keymap.set("i", "<Tab>", function()
    if self.actions.command_menu_visible() then
      self.actions.select_command(1)
      return
    end
    local line = vim.api.nvim_get_current_line()
    if line:match("^%s*/") and self.actions.update_command_menu() then
      return
    end
    feed("<Tab>")
  end, { buffer = input_buf, silent = true, desc = "Complete or indent Pi prompt" })
  vim.keymap.set("i", "<C-v>", function()
    self:_paste_clipboard(true)
  end, { buffer = input_buf, silent = true, desc = "Paste into Pi prompt" })
  vim.keymap.set("i", "<C-S-v>", function()
    self:_paste_clipboard(true)
  end, { buffer = input_buf, silent = true, desc = "Paste into Pi prompt" })
  vim.keymap.set("i", "<Down>", function()
    self:_clear_attachment_selection()
    if not self.actions.select_command(1) then
      feed("<Down>")
    end
  end, { buffer = input_buf, silent = true, desc = "Select next Pi command" })
  vim.keymap.set("i", "<Up>", function()
    self:_clear_attachment_selection()
    if not self.actions.select_command(-1) then
      feed("<Up>")
    end
  end, { buffer = input_buf, silent = true, desc = "Select previous Pi command" })
  vim.keymap.set("i", "<C-n>", function()
    if not self.actions.select_command(1) then
      feed("<C-n>")
    end
  end, { buffer = input_buf, silent = true, desc = "Select next Pi command" })
  vim.keymap.set("i", "<Right>", function()
    local count = self:_pending_image_count()
    if self.selected_attachment_index then
      if self.selected_attachment_index < count then
        self:_select_attachment(self.selected_attachment_index + 1)
      end
      return
    end
    local index = self:_attachment_at_cursor(true)
    if count > 0 and index then
      self:_select_attachment(index)
      return
    end
    feed("<Right>")
  end, { buffer = input_buf, silent = true, desc = "Move right through Pi attachments" })
  vim.keymap.set("i", "<Left>", function()
    if self.selected_attachment_index and self.selected_attachment_index > 1 then
      self:_select_attachment(self.selected_attachment_index - 1)
    elseif self.selected_attachment_index then
      local position = self:_position_for_attachment(1)
      self:_clear_attachment_selection()
      if position then
        vim.api.nvim_win_set_cursor(self.input_win, { position.row, position.col })
      end
    else
      local index = self:_attachment_at_cursor(false)
      if index then
        self:_select_attachment(index)
      else
        feed("<Left>")
      end
    end
  end, { buffer = input_buf, silent = true, desc = "Move left through Pi attachments" })
  vim.keymap.set("i", "<Home>", function()
    self:_clear_attachment_selection()
    feed("<Home>")
  end, { buffer = input_buf, silent = true, desc = "Move to start of Pi prompt" })
  vim.keymap.set("i", "<End>", function()
    self:_clear_attachment_selection()
    feed("<End>")
  end, { buffer = input_buf, silent = true, desc = "Move to end of Pi prompt" })
  vim.keymap.set("i", "<BS>", function()
    if not self:_delete_selected_attachment(true) then
      feed("<BS>")
    end
  end, { buffer = input_buf, silent = true, desc = "Delete before Pi prompt cursor" })
  vim.keymap.set("i", "<Del>", function()
    if not self:_delete_selected_attachment(false) then
      feed("<Del>")
    end
  end, { buffer = input_buf, silent = true, desc = "Delete at Pi prompt cursor" })
  vim.keymap.set("i", "<Esc>", function()
    if self:_clear_attachment_selection() then
      return
    end
    if self.actions.command_menu_visible() then
      self.actions.close_command_menu()
      return
    end
    local activity = self.state_provider().activity
    if activity ~= "idle" and activity ~= "starting" then
      self.actions.abort()
      return
    end
    self.insert_guard_generation = self.insert_guard_generation + 1
    vim.cmd("stopinsert")
    self.actions.focus_transcript()
  end, { buffer = input_buf, silent = true, desc = "Dismiss Pi prompt or interrupt active work" })
  vim.keymap.set({ "n", "i", "v" }, "<C-q>", function()
    self.actions.close_command_menu()
    vim.cmd("stopinsert")
    self.actions.return_to_editor()
  end, { buffer = input_buf, silent = true, desc = "Return from Pi to editor" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    self.actions.abort()
  end, { buffer = input_buf, silent = true, desc = "Interrupt Pi" })
  vim.keymap.set({ "n", "i" }, "<C-l>", function()
    self.actions.prefill_command("/model ")
  end, { buffer = input_buf, silent = true, desc = "Select Pi model" })
  vim.keymap.set("n", "<C-p>", function()
    self.actions.prefill_command("/model ")
  end, { buffer = input_buf, silent = true, desc = "Select Pi model" })
  vim.keymap.set("i", "<C-p>", function()
    if self.actions.select_command(-1) then
      return
    end
    self.actions.prefill_command("/model ")
  end, { buffer = input_buf, silent = true, desc = "Navigate command or select Pi model" })
  vim.keymap.set({ "n", "i" }, "<M-p>", function()
    self.actions.prefill_command("/permissions ")
  end, { buffer = input_buf, silent = true, desc = "Select Pi permission mode" })
  vim.keymap.set("n", "<S-Tab>", function()
    self.actions.prefill_command("/thinking ")
  end, { buffer = input_buf, silent = true, desc = "Select Pi thinking level" })
  vim.keymap.set("i", "<S-Tab>", function()
    if self.actions.select_command(-1) then
      return
    end
    self.actions.prefill_command("/thinking ")
  end, { buffer = input_buf, silent = true, desc = "Navigate command or select Pi thinking level" })
  vim.keymap.set({ "n", "i" }, "<C-o>", function()
    self.actions.toggle_tools()
  end, { buffer = input_buf, silent = true, desc = "Toggle Pi process details" })
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    self.actions.toggle_thinking()
  end, { buffer = input_buf, silent = true, desc = "Toggle Pi process details" })
  vim.keymap.set({ "n", "i" }, "<LeftMouse>", function()
    self:_clear_attachment_selection()
    dispatch_left_mouse(self.actions.left_mouse)
  end, { buffer = input_buf, silent = true, desc = "Interact with Pi transcript" })
  vim.keymap.set({ "n", "i" }, "<RightMouse>", function()
    self:_clear_attachment_selection()
    self:paste_at_mouse()
  end, { buffer = input_buf, silent = true, desc = "Paste into Pi prompt at pointer" })
  self:render_attachments()
  return input_buf
end

function InputArea:ensure_status_buffer()
  if self.status_buf and vim.api.nvim_buf_is_valid(self.status_buf) then
    return self.status_buf
  end
  self.status_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.status_buf, "status", self.root)
  vim.bo[self.status_buf].buftype = "nofile"
  vim.bo[self.status_buf].bufhidden = "hide"
  vim.bo[self.status_buf].swapfile = false
  vim.bo[self.status_buf].filetype = "pi_status"
  vim.bo[self.status_buf].modifiable = false
  return self.status_buf
end

function InputArea:set_windows(input_win, status_win)
  self.input_win = input_win
  self.status_win = status_win
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    vim.wo[input_win].conceallevel = 2
    vim.wo[input_win].concealcursor = "niv"
  end
end

function InputArea:buffer()
  return self.input_buf
end

function InputArea:window()
  return self.input_win
end

function InputArea:status_buffer()
  return self.status_buf
end

function InputArea:status_window()
  return self.status_win
end

function InputArea:close_windows()
  self.insert_guard_generation = self.insert_guard_generation + 1
  self:_clear_attachment_selection()
  for _, win in pairs({ self.status_win, self.input_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  self.status_win = nil
  self.input_win = nil
end

function InputArea:owns_buffer(bufnr)
  return type(bufnr) == "number"
    and vim.api.nvim_buf_is_valid(bufnr)
    and (self.input_buf == bufnr or self.status_buf == bufnr)
end

function InputArea:destroy()
  self:close_windows()
  for _, buf in pairs({ self.status_buf, self.input_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  self.status_buf = nil
  self.input_buf = nil
end

M.InputArea = InputArea
M.name_buffer = name_buffer
M.dispatch_left_mouse = dispatch_left_mouse
M.truncate_display = truncate_display
M.attachment_marker = attachment_marker
return M
