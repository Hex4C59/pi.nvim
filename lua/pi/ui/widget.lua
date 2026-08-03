local config = require("pi.config")

local M = {}
local WidgetArea = {}
WidgetArea.__index = WidgetArea

local MAX_WIDGETS = 16
local MAX_LINES_PER_WIDGET = 100
local MAX_LINE_CHARS = 2048
local TRANSCRIPT_WIDGETS = {
  ["pi.todo"] = true,
}

local function maximum_height()
  local configured = tonumber((config.get().chat or {}).max_widget_height) or 8
  if configured ~= configured or configured == math.huge or configured == -math.huge then
    configured = 8
  end
  return math.max(0, math.floor(configured))
end

local function close_window(slot)
  if slot.win and vim.api.nvim_win_is_valid(slot.win) then
    vim.api.nvim_win_close(slot.win, true)
  end
  slot.win = nil
end

local function clear_buffer(slot, namespace)
  if not slot.buf or not vim.api.nvim_buf_is_valid(slot.buf) then
    return
  end
  vim.bo[slot.buf].modifiable = true
  vim.api.nvim_buf_set_lines(slot.buf, 0, -1, false, { "" })
  vim.bo[slot.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(slot.buf, namespace, 0, -1)
end

local function sanitize_line(line)
  line = line:gsub("%z", ""):gsub("[\r\n]", " ")
  if vim.fn.strchars(line) > MAX_LINE_CHARS then
    line = vim.fn.strcharpart(line, 0, MAX_LINE_CHARS) .. "..."
  end
  return line
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
  local result = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local candidate = result .. vim.fn.strcharpart(text, index, 1)
    if vim.api.nvim_strwidth(candidate) > target then
      break
    end
    result = candidate
  end
  return result .. "..."
end

local function wrap_display(text, width)
  width = math.max(1, math.floor(width or 1))
  local characters = {}
  for index = 0, vim.fn.strchars(text) - 1 do
    table.insert(characters, vim.fn.strcharpart(text, index, 1))
  end
  if #characters == 0 then
    return { "" }
  end

  local lines = {}
  local first = 1
  while first <= #characters do
    local used = 0
    local last = first - 1
    local last_space = nil
    while last < #characters do
      local character = characters[last + 1]
      local character_width = vim.fn.strdisplaywidth(character)
      if last >= first and used + character_width > width then
        break
      end
      last = last + 1
      used = used + character_width
      if character:match("%s") then
        last_space = last
      end
    end

    local next_first = last + 1
    if last < #characters and last_space and last_space > first then
      last = last_space - 1
      next_first = last_space + 1
      while next_first <= #characters and characters[next_first]:match("%s") do
        next_first = next_first + 1
      end
    end
    table.insert(lines, table.concat(characters, "", first, last))
    first = next_first
  end
  return lines
end

local function line_highlight(key, index, line)
  if index == 1 then
    return "PiWidgetTitle"
  end
  if key ~= "pi.todo" then
    return "PiWidgetText"
  end
  if vim.startswith(line, "◐ ") then
    return "PiWidgetActive"
  elseif vim.startswith(line, "○ ") then
    return "PiWidgetPending"
  elseif vim.startswith(line, "✓ ") then
    return "PiWidgetCompleted"
  elseif vim.startswith(line, "… ") then
    return "PiWidgetMuted"
  end
  return "PiWidgetText"
end

local function todo_highlight(line)
  if vim.startswith(line, "◐ ") then
    return "PiPlanActive"
  elseif vim.startswith(line, "○ ") then
    return "PiPlanPending"
  elseif vim.startswith(line, "✓ ") then
    return "PiPlanCompleted"
  elseif vim.startswith(line, "… ") then
    return "PiPlanMuted"
  end
  return "PiPlanText"
end

local function todo_marker(line)
  for _, marker in ipairs({ "◐ ", "○ ", "✓ ", "… " }) do
    if vim.startswith(line, marker) then
      return marker
    end
  end
  return ""
end

local function add_text_mark(marks, row, start_col, end_col, highlight)
  if end_col <= start_col then
    return
  end
  table.insert(marks, {
    row = row,
    start_col = start_col,
    end_col = end_col,
    highlight = highlight,
    priority = 100,
  })
end

local function render_todo(lines, width)
  width = math.max(1, math.floor(width or 1))
  local rendered = {}
  local marks = {}
  local title = lines[1]
  if not title then
    return rendered, marks
  end

  local title_prefix = "• "
  local title_line = truncate_display(title_prefix .. title, width)
  table.insert(rendered, title_line)
  add_text_mark(marks, 0, 0, math.min(#title_prefix, #title_line), "PiPlanMarker")
  add_text_mark(marks, 0, math.min(#title_prefix, #title_line), #title_line, "PiPlanTitle")

  for index = 2, #lines do
    local line = lines[index]
    local marker = todo_marker(line)
    local text = marker ~= "" and line:sub(#marker + 1) or line
    local branch = index == 2 and "  └ " or "    "
    local first_prefix = branch .. marker
    local continuation_prefix = string.rep(" ", vim.fn.strdisplaywidth(first_prefix))
    local content_width = math.max(1, width - vim.fn.strdisplaywidth(first_prefix))
    local group = todo_highlight(line)
    for wrapped_index, wrapped in ipairs(wrap_display(text, content_width)) do
      local prefix = wrapped_index == 1 and first_prefix or continuation_prefix
      local rendered_line = prefix .. wrapped
      local row = #rendered
      table.insert(rendered, rendered_line)
      add_text_mark(marks, row, 0, #rendered_line, group)
    end
  end
  return rendered, marks
end

function WidgetArea.new(chat, deps)
  return setmetatable({
    chat = chat,
    namespace = deps.namespace,
    widgets = {},
    slots = {
      aboveEditor = { placement = "aboveEditor", buf = nil, win = nil },
      belowEditor = { placement = "belowEditor", buf = nil, win = nil },
    },
  }, WidgetArea)
end

function WidgetArea:_ensure_buffer(slot)
  if slot.buf and vim.api.nvim_buf_is_valid(slot.buf) then
    return slot.buf
  end
  slot.buf = vim.api.nvim_create_buf(false, true)
  local name = ("Pi Widgets %s · %s"):format(slot.placement, vim.fs.basename(self.chat.root))
  if not pcall(vim.api.nvim_buf_set_name, slot.buf, name) then
    vim.api.nvim_buf_set_name(slot.buf, name .. " · " .. vim.fn.sha256(self.chat.root):sub(1, 6))
  end
  vim.b[slot.buf].pi_kind = "widget"
  vim.b[slot.buf].pi_widget_placement = slot.placement
  vim.b[slot.buf].pi_root = self.chat.root
  vim.bo[slot.buf].buftype = "nofile"
  vim.bo[slot.buf].bufhidden = "hide"
  vim.bo[slot.buf].swapfile = false
  vim.bo[slot.buf].filetype = "pi_widget"
  vim.b[slot.buf].completion = false
  vim.bo[slot.buf].complete = ""
  vim.bo[slot.buf].completefunc = ""
  vim.bo[slot.buf].omnifunc = ""
  vim.bo[slot.buf].modifiable = false
  return slot.buf
end

function WidgetArea:_ensure_window(slot)
  if slot.win and vim.api.nvim_win_is_valid(slot.win) then
    return slot.win
  end
  if not self.chat.win or not vim.api.nvim_win_is_valid(self.chat.win) then
    return nil
  end
  slot.win = vim.api.nvim_open_win(self:_ensure_buffer(slot), false, {
    relative = "win",
    win = self.chat.win,
    row = 0,
    col = 0,
    width = 1,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 49,
  })
  local options = vim.wo[slot.win]
  options.wrap = false
  options.number = false
  options.relativenumber = false
  options.signcolumn = "no"
  options.foldcolumn = "0"
  options.cursorline = false
  options.spell = false
  options.fillchars = "eob: "
  options.winbar = ""
  options.winblend = 0
  pcall(function()
    options.winfixbuf = true
  end)
  options.winhighlight = table.concat({
    "Normal:PiWidgetNormal",
    "NormalNC:PiWidgetNormal",
    "EndOfBuffer:PiWidgetNormal",
    "WinSeparator:PiWidgetNormal",
  }, ",")
  return slot.win
end

function WidgetArea:set(key, lines, placement)
  if type(key) ~= "string" or key == "" or #key > 128 then
    return false
  end
  if lines == nil or (type(lines) == "table" and #lines == 0) then
    local previous = self.widgets[key]
    self.widgets[key] = nil
    if previous and not TRANSCRIPT_WIDGETS[key] then
      local still_used = false
      for widget_key, widget in pairs(self.widgets) do
        still_used = still_used or (not TRANSCRIPT_WIDGETS[widget_key] and widget.placement == previous.placement)
      end
      if not still_used then
        clear_buffer(self.slots[previous.placement], self.namespace)
      end
    end
    self.chat:_layout()
    if TRANSCRIPT_WIDGETS[key] then
      self.chat:_render_transcript()
    end
    return true
  end
  if type(lines) ~= "table" then
    return false
  end
  if self.widgets[key] == nil and vim.tbl_count(self.widgets) >= MAX_WIDGETS then
    return false
  end
  local sanitized = {}
  for index, line in ipairs(lines) do
    if index > MAX_LINES_PER_WIDGET then
      break
    end
    if type(line) ~= "string" then
      return false
    end
    table.insert(sanitized, sanitize_line(line))
  end
  if #sanitized == 0 then
    self.widgets[key] = nil
  else
    self.widgets[key] = {
      lines = sanitized,
      placement = placement == "belowEditor" and "belowEditor" or "aboveEditor",
    }
  end
  self.chat:_layout()
  if TRANSCRIPT_WIDGETS[key] then
    self.chat:_render_transcript()
  end
  return true
end

function WidgetArea:_content(placement, width, transcript)
  local keys = vim.tbl_keys(self.widgets)
  table.sort(keys)
  local lines = {}
  local highlights = {}
  for _, key in ipairs(keys) do
    local widget = self.widgets[key]
    local is_transcript = TRANSCRIPT_WIDGETS[key] == true
    if is_transcript == (transcript == true) and (is_transcript or widget.placement == placement) then
      if #lines > 0 then
        table.insert(lines, "")
        table.insert(highlights, "PiWidgetNormal")
      end
      for index, line in ipairs(widget.lines) do
        table.insert(lines, truncate_display(line, width))
        table.insert(highlights, line_highlight(key, index, line))
      end
    end
  end
  return lines, highlights
end

local function bounded_content(lines, groups, height)
  if #lines <= height then
    return lines, groups
  end
  if height < 1 then
    return {}, {}
  end

  local omitted = #lines - height
  lines = vim.list_slice(lines, 1, height)
  groups = vim.list_slice(groups, 1, height)
  if height > 1 then
    lines[height] = ("… %d more"):format(omitted + 1)
    groups[height] = "PiWidgetMuted"
  end
  return lines, groups
end

function WidgetArea:transcript_content(width)
  local widget = self.widgets["pi.todo"]
  if not widget then
    return {}, {}
  end

  local lines, marks = render_todo(widget.lines, width)
  local height = maximum_height()
  if #lines <= height then
    return lines, marks
  end
  if height < 1 then
    return {}, {}
  end

  local omitted = #lines - height + 1
  lines = vim.list_slice(lines, 1, height)
  local retained_marks = {}
  local replaced_row = height > 1 and height - 1 or height
  for _, mark in ipairs(marks) do
    if mark.row < replaced_row then
      table.insert(retained_marks, mark)
    end
  end
  if height > 1 then
    lines[height] = truncate_display(("    … %d more"):format(omitted), width)
    add_text_mark(retained_marks, height - 1, 0, #lines[height], "PiPlanMuted")
  end
  return lines, retained_marks
end

function WidgetArea:measure(width, available)
  local budget = math.max(0, math.min(maximum_height(), math.floor(available or 0)))
  local above = #self:_content("aboveEditor", width)
  local below = #self:_content("belowEditor", width)
  local below_reserve = below > 0 and budget > 1 and math.min(below, math.floor(budget / 2)) or 0
  local above_height = math.min(above, budget - below_reserve)
  local below_height = math.min(below, math.max(0, budget - above_height))
  above_height = math.min(above, above_height + math.max(0, budget - above_height - below_height))
  return above_height, below_height
end

function WidgetArea:_render(slot, width, height, row)
  if height < 1 then
    close_window(slot)
    clear_buffer(slot, self.namespace)
    return
  end
  local lines, groups = self:_content(slot.placement, width)
  lines, groups = bounded_content(lines, groups, height)

  local buf = self:_ensure_buffer(slot)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.namespace, 0, -1)
  for index, group in ipairs(groups) do
    vim.api.nvim_buf_set_extmark(buf, self.namespace, index - 1, 0, {
      line_hl_group = group,
      priority = 100,
    })
  end

  local win = self:_ensure_window(slot)
  if not win then
    return
  end
  vim.api.nvim_win_set_config(win, {
    relative = "win",
    win = self.chat.win,
    row = math.max(0, row),
    col = 0,
    width = math.max(1, width),
    height = height,
    style = "minimal",
    focusable = false,
    zindex = 49,
  })
end

function WidgetArea:owns_buffer(buf)
  if buf == nil then
    return false
  end
  for _, slot in pairs(self.slots) do
    if slot.buf == buf then
      return true
    end
  end
  return false
end

function WidgetArea:buffer(placement)
  local slot = self.slots[placement or "aboveEditor"]
  return slot and slot.buf or nil
end

function WidgetArea:window(placement)
  local slot = self.slots[placement or "aboveEditor"]
  return slot and slot.win or nil
end

function WidgetArea:layout(width, input_row, input_height, above_height, below_height)
  self:_render(self.slots.aboveEditor, width, above_height, input_row - above_height)
  self:_render(self.slots.belowEditor, width, below_height, input_row + input_height + 2)
end

function WidgetArea:close_windows()
  for _, slot in pairs(self.slots) do
    close_window(slot)
  end
end

function WidgetArea:clear()
  local had_transcript_widget = false
  for key in pairs(self.widgets) do
    had_transcript_widget = had_transcript_widget or TRANSCRIPT_WIDGETS[key] == true
  end
  self.widgets = {}
  self:close_windows()
  for _, slot in pairs(self.slots) do
    clear_buffer(slot, self.namespace)
  end
  self.chat:_layout()
  if had_transcript_widget then
    self.chat:_render_transcript()
  end
end

function WidgetArea:destroy()
  self.widgets = {}
  self:close_windows()
  for _, slot in pairs(self.slots) do
    if slot.buf and vim.api.nvim_buf_is_valid(slot.buf) then
      pcall(vim.api.nvim_buf_delete, slot.buf, { force = true })
    end
    slot.buf = nil
  end
end

M.WidgetArea = WidgetArea
return M
