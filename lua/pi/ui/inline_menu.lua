local truncate_display = require("pi.format").truncate_display

local M = {}
local InlineMenu = {}
InlineMenu.__index = InlineMenu

local MAX_DEPTH = 8
local MAX_ITEMS = 2000
local MAX_QUERY_CHARS = 256
local MAX_LINE_CHARS = 512
local MAX_VISIBLE_HEIGHT = 14

local function clean_line(value)
  value = tostring(value or ""):gsub("[\r\n]+", " ")
  return vim.fn.strcharpart(value, 0, MAX_LINE_CHARS)
end

local function bounded_query(value)
  value = tostring(value or ""):gsub("[\r\n]", "")
  return vim.fn.strcharpart(value, 0, MAX_QUERY_CHARS)
end

local function default_key(item, index)
  if type(item) == "table" then
    if item.provider ~= nil and item.id ~= nil then
      return tostring(item.provider) .. "\0" .. tostring(item.id)
    end
    for _, field in ipairs({ "value", "id", "entryId", "path", "name" }) do
      if item[field] ~= nil then
        return field .. "\0" .. tostring(item[field])
      end
    end
  end
  if type(item) ~= "table" then
    return type(item) .. "\0" .. tostring(item)
  end
  return type(item) .. "\0" .. tostring(item) .. "\0" .. tostring(index)
end

local function item_key(frame, item, index)
  if type(frame.key_item) == "function" then
    local ok, key = pcall(frame.key_item, item)
    if ok and key ~= nil then
      return tostring(key)
    end
  end
  return default_key(item, index)
end

local function item_label(frame, item)
  if type(frame.format_item) == "function" then
    local ok, label = pcall(frame.format_item, item)
    if ok then
      return clean_line(label)
    end
  end
  if type(item) == "table" then
    return clean_line(item.label or item.name or item.id or item.value or "")
  end
  return clean_line(item)
end

local function item_description(frame, item)
  if type(frame.describe_item) == "function" then
    local ok, description = pcall(frame.describe_item, item)
    if ok then
      return clean_line(description)
    end
  end
  return type(item) == "table" and clean_line(item.description or "") or ""
end

local function fuzzy_score(text, query)
  text = text:lower()
  query = query:lower()
  if query == "" then
    return 0
  end
  local direct = text:find(query, 1, true)
  if direct then
    return 100000 - direct * 10 - #text
  end
  local cursor = 1
  local score = 0
  local previous
  for index = 1, #query do
    local character = query:sub(index, index)
    local position = text:find(character, cursor, true)
    if not position then
      return nil
    end
    score = score + (previous and position == previous + 1 and 20 or 1)
    if position == 1 or text:sub(position - 1, position - 1):match("[%s%p]") then
      score = score + 8
    end
    previous = position
    cursor = position + 1
  end
  return score - #text
end

local function shallow_copy(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    copy[key] = value
  end
  return copy
end

function InlineMenu.new(deps)
  return setmetatable({
    deps = deps,
    root = deps.root,
    namespace = deps.namespace,
    name_buffer = deps.name_buffer,
    stack = {},
    buf = nil,
    win = nil,
    generation = 0,
    next_frame_id = 0,
    autocmds = {},
    destroyed = false,
    closing = false,
  }, InlineMenu)
end

function InlineMenu:active()
  return not self.destroyed and #self.stack > 0
end

function InlineMenu:visible()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function InlineMenu:buffer()
  return self.buf
end

function InlineMenu:window()
  return self.win
end

function InlineMenu:owns_buffer(bufnr)
  return self.buf ~= nil and self.buf == bufnr
end

function InlineMenu:_frame()
  return self.stack[#self.stack]
end

function InlineMenu:_surface_current(surface)
  if self.destroyed or surface.closed or surface.generation ~= self.generation then
    return false
  end
  for _, frame in ipairs(self.stack) do
    if frame.id == surface.frame_id then
      return true
    end
  end
  return false
end

function InlineMenu:_mark_closed(frame)
  if frame and frame.surface then
    frame.surface.closed = true
  end
end

function InlineMenu:_make_surface(frame)
  local menu = self
  local surface = {
    closed = false,
    generation = self.generation,
    frame_id = frame.id,
  }

  function surface:close()
    if menu:_surface_current(self) then
      menu:close()
    else
      self.closed = true
    end
  end

  function surface:append(items, next_cursor)
    return menu:_append(self, items, next_cursor)
  end

  function surface:set_loading(cursor)
    return menu:_set_loading(self, cursor)
  end

  function surface:set_error(message)
    return menu:_set_error(self, message)
  end

  function surface:push(options)
    if not menu:_surface_current(self) then
      return nil
    end
    return menu:push(options)
  end

  function surface:replace(options)
    if not menu:_surface_current(self) then
      return nil
    end
    return menu:replace(options)
  end

  frame.surface = surface
  return surface
end

function InlineMenu:_add_items(frame, items)
  local added = 0
  for _, item in ipairs(items or {}) do
    if #frame.items >= MAX_ITEMS then
      frame.truncated = true
      break
    end
    local key = item_key(frame, item, #frame.items + 1)
    if not frame.item_keys[key] then
      frame.item_keys[key] = true
      table.insert(frame.items, {
        value = item,
        key = key,
        label = item_label(frame, item),
        description = item_description(frame, item),
        source_index = #frame.items + 1,
      })
      added = added + 1
    end
  end
  return added
end

function InlineMenu:_new_frame(options)
  options = shallow_copy(options)
  self.next_frame_id = self.next_frame_id + 1
  local kind = options.kind or "select"
  local frame = {
    id = self.next_frame_id,
    kind = kind,
    title = clean_line(options.title or "Pi"),
    message = clean_line(options.message or ""),
    placeholder = clean_line(options.placeholder or ""),
    query = bounded_query(options.query or options.default or ""),
    format_item = options.format_item,
    describe_item = options.describe_item,
    key_item = options.key_item,
    on_select = options.on_select,
    on_submit = options.on_submit,
    on_confirm = options.on_confirm,
    on_cancel = options.on_cancel,
    on_empty = options.on_empty,
    on_more = options.on_more,
    keep_open = options.keep_open == true,
    items = {},
    item_keys = {},
    selected_keys = {},
    filtered = {},
    current = 1,
    first = 1,
    next_cursor = options.next_cursor,
    pending_cursor = nil,
    loading = options.loading == true,
    error = options.error and clean_line(options.error) or nil,
    truncated = false,
  }

  if kind == "confirm" then
    options.items = {
      { label = options.cancel_label or "Cancel", confirmed = false, value = false },
      { label = options.confirm_label or "Confirm", confirmed = true, value = true },
    }
  end
  self:_add_items(frame, options.items or {})

  if kind == "multi_select" then
    for index, item in ipairs(options.selected or {}) do
      frame.selected_keys[item_key(frame, item, index)] = true
    end
  end
  if options.current ~= nil then
    frame.current_key = item_key(frame, options.current, 0)
  elseif options.current_key ~= nil then
    frame.current_key = tostring(options.current_key)
  end
  self:_refresh(frame)
  return frame
end

function InlineMenu:_refresh(frame)
  local selected_key = frame.filtered[frame.current] and frame.filtered[frame.current].key
  local ranked = {}
  for _, row in ipairs(frame.items) do
    local score = fuzzy_score(row.label .. " " .. row.description, frame.kind == "input" and "" or frame.query)
    if score ~= nil then
      table.insert(ranked, { row = row, score = score })
    end
  end
  table.sort(ranked, function(left, right)
    if left.score == right.score then
      return left.row.source_index < right.row.source_index
    end
    return left.score > right.score
  end)
  frame.filtered = {}
  for _, entry in ipairs(ranked) do
    table.insert(frame.filtered, entry.row)
  end
  if frame.loading or (type(frame.on_more) == "function" and (frame.error or frame.next_cursor ~= nil)) then
    table.insert(frame.filtered, {
      kind = frame.loading and "loading" or frame.error and "retry" or "more",
      key = "\0pi-pagination",
      label = frame.loading and "Loading more..." or frame.error and "Retry loading more" or "Load more...",
      description = "",
    })
  end
  frame.current = 1
  if selected_key then
    for index, row in ipairs(frame.filtered) do
      if row.key == selected_key then
        frame.current = index
        break
      end
    end
  elseif frame.current_key then
    for index, row in ipairs(frame.filtered) do
      if row.key == frame.current_key then
        frame.current = index
        break
      end
    end
  end
  frame.current = math.max(1, math.min(frame.current, math.max(1, #frame.filtered)))
  frame.first = math.max(1, math.min(frame.first, frame.current))
end

function InlineMenu:_ensure_buffer()
  if self.destroyed then
    return nil
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end
  self.buf = vim.api.nvim_create_buf(false, true)
  local buf = self.buf
  self.name_buffer(buf, "inline-menu", self.root)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].filetype = "pi_inline_menu"
  vim.bo[buf].modifiable = false

  local function map(lhs, callback)
    vim.keymap.set("n", lhs, callback, { buffer = buf, silent = true, nowait = true })
  end
  for _, key in ipairs({ "<Down>", "<C-n>" }) do
    map(key, function()
      self:move(1)
    end)
  end
  for _, key in ipairs({ "<Up>", "<C-p>" }) do
    map(key, function()
      self:move(-1)
    end)
  end
  for _, key in ipairs({ "<BS>", "<C-h>" }) do
    map(key, function()
      self:backspace()
    end)
  end
  map("<CR>", function()
    self:submit()
  end)
  map("<Tab>", function()
    self:toggle()
  end)
  map("<Esc>", function()
    self:back()
  end)
  map("<C-q>", function()
    self:cancel_group(true)
  end)

  for byte = 32, 126 do
    local character = string.char(byte)
    local lhs = character == " " and "<Space>" or character == "<" and "<lt>" or character
    map(lhs, function()
      self:insert(character)
    end)
  end

  table.insert(
    self.autocmds,
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = buf,
      once = true,
      callback = function()
        if self.buf == buf then
          self.buf = nil
          self:close({ focus = false })
        end
      end,
    })
  )
  return buf
end

function InlineMenu:_ensure_window()
  if self:visible() then
    return self.win
  end
  local main_win = self.deps.main_window()
  if not main_win or not vim.api.nvim_win_is_valid(main_win) then
    return nil
  end
  local buf = self:_ensure_buffer()
  if not buf then
    return nil
  end
  self.win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = main_win,
    row = 0,
    col = 0,
    width = 1,
    height = 1,
    style = "minimal",
    focusable = true,
    zindex = 53,
  })
  local win = self.win
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winblend = 0
  vim.wo[win].winbar = ""
  vim.wo[win].winhighlight = table.concat({
    "Normal:PiInlineMenu",
    "NormalNC:PiInlineMenu",
    "EndOfBuffer:PiInlineMenu",
    "WinSeparator:PiInlineMenu",
  }, ",")
  table.insert(
    self.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      callback = function()
        if self.win == win then
          self.win = nil
          if not self.closing then
            self:close()
          end
        end
      end,
    })
  )
  return win
end

function InlineMenu:_title()
  local titles = {}
  for _, frame in ipairs(self.stack) do
    table.insert(titles, frame.title)
  end
  return table.concat(titles, " / ")
end

function InlineMenu:desired_height()
  local frame = self:_frame()
  if not frame then
    return 0
  end
  local header = 2 + (frame.message ~= "" and 1 or 0) + ((frame.error or frame.loading) and 1 or 0)
  local rows = frame.kind == "input" and 1 or math.max(1, #frame.filtered)
  return math.min(MAX_VISIBLE_HEIGHT, header + rows + 1)
end

local function add_highlight(buf, namespace, row, start_col, end_col, group, line)
  if line then
    vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, { line_hl_group = group, priority = 80 })
  elseif end_col > start_col then
    vim.api.nvim_buf_set_extmark(buf, namespace, row, start_col, {
      end_col = end_col,
      hl_group = group,
      priority = 140,
    })
  end
end

function InlineMenu:_render(width, height)
  local frame = self:_frame()
  local buf = self:_ensure_buffer()
  if not frame or not buf then
    return
  end
  local content_width = math.max(1, width - 4)
  local lines = {}
  local marks = {}
  local function line(text, mark)
    table.insert(lines, truncate_display(text, math.max(1, width)))
    if mark then
      mark.row = #lines - 1
      table.insert(marks, mark)
    end
  end

  line("  " .. self:_title(), { start_col = 2, group = "PiInlineTitle" })
  if frame.message ~= "" then
    line("  " .. truncate_display(frame.message, content_width), { start_col = 2, group = "PiInlineDescription" })
  end
  local field_label = frame.kind == "input" and "Value: " or "Filter: "
  line("  " .. field_label .. frame.query, {
    start_col = 2,
    label_end = 2 + #field_label,
    group = "PiInlineQuery",
    value_group = "PiInlineInput",
  })
  if frame.error then
    line("  ! " .. truncate_display(frame.error, math.max(1, content_width - 2)), {
      start_col = 2,
      group = "PiInlineError",
    })
  elseif frame.loading then
    line("  Loading...", { start_col = 2, group = "PiInlineLoading" })
  end

  local fixed = #lines + 1
  local row_budget = math.max(1, height - fixed)
  if frame.kind == "input" then
    local empty_placeholder = frame.query == "" and frame.placeholder ~= ""
    local value = frame.query ~= "" and frame.query or empty_placeholder and frame.placeholder or "_"
    line("  " .. value, {
      start_col = 2,
      group = empty_placeholder and "PiInlineDescription" or "PiInlineInput",
      selected = true,
    })
  elseif #frame.filtered == 0 then
    line("  No matches", { start_col = 2, group = "PiInlineDescription" })
  else
    local maximum_first = math.max(1, #frame.filtered - row_budget + 1)
    local first = math.max(1, math.min(frame.first, maximum_first))
    if frame.current < first then
      first = frame.current
    elseif frame.current >= first + row_budget then
      first = frame.current - row_budget + 1
    end
    frame.first = first
    for index = first, math.min(#frame.filtered, first + row_budget - 1) do
      local row = frame.filtered[index]
      local selected = index == frame.current
      local pointer = selected and ">" or " "
      local state = " "
      if frame.kind == "multi_select" then
        state = frame.selected_keys[row.key] and "[x]" or "[ ]"
      elseif row.key == frame.current_key then
        state = "*"
      end
      local prefix = pointer .. " " .. state .. " "
      local description = row.description or ""
      local label_width = content_width
      local description_width = 0
      if description ~= "" and content_width >= 30 then
        label_width = math.max(12, math.floor(content_width * 0.56))
        description_width = math.max(8, content_width - label_width - 2)
      end
      local label = truncate_display(row.label, label_width)
      local padding = string.rep(" ", math.max(0, label_width - vim.fn.strdisplaywidth(label)))
      local suffix = description_width > 0 and ("  " .. truncate_display(description, description_width)) or ""
      line(prefix .. label .. padding .. suffix, {
        start_col = #prefix,
        label_end = #prefix + #label,
        description_start = #prefix + #label + #padding + (description_width > 0 and 2 or 0),
        selected = selected,
        marker_end = #prefix,
        current = row.key == frame.current_key,
        loading = row.kind == "loading",
      })
    end
  end

  local status
  if frame.kind == "input" then
    status = ("%d/%d characters"):format(vim.fn.strchars(frame.query), MAX_QUERY_CHARS)
  else
    local visible_items = 0
    for _, row in ipairs(frame.filtered) do
      if not row.kind then
        visible_items = visible_items + 1
      end
    end
    status = ("%d of %d"):format(visible_items, #frame.items)
    if frame.truncated then
      status = status .. (" (limited to %d)"):format(MAX_ITEMS)
    end
  end
  line("  " .. status, { start_col = 2, group = "PiInlineDescription" })

  while #lines > height do
    table.remove(lines, #lines - 1)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.namespace, 0, -1)
  for _, mark in ipairs(marks) do
    if mark.row < #lines then
      if mark.selected then
        add_highlight(buf, self.namespace, mark.row, 0, 0, "PiInlineSelected", true)
      end
      if mark.group then
        local line_text = lines[mark.row + 1] or ""
        local finish = mark.label_end or #line_text
        add_highlight(buf, self.namespace, mark.row, mark.start_col or 0, finish, mark.group)
        if mark.value_group and #line_text > (mark.label_end or 0) then
          add_highlight(buf, self.namespace, mark.row, mark.label_end, #line_text, mark.value_group)
        end
      else
        add_highlight(
          buf,
          self.namespace,
          mark.row,
          0,
          math.min(mark.marker_end or 0, #(lines[mark.row + 1] or "")),
          "PiInlineMarker"
        )
        local line_text = lines[mark.row + 1] or ""
        add_highlight(
          buf,
          self.namespace,
          mark.row,
          mark.start_col or 0,
          math.min(mark.label_end or #line_text, #line_text),
          mark.current and "PiInlineCurrent" or mark.loading and "PiInlineLoading" or "PiInlineItem"
        )
        if mark.description_start and mark.description_start < #line_text then
          add_highlight(buf, self.namespace, mark.row, mark.description_start, #line_text, "PiInlineDescription")
        end
      end
    end
  end
end

function InlineMenu:layout(row, width, height)
  if not self:active() then
    return false
  end
  local main_win = self.deps.main_window()
  local win = self:_ensure_window()
  if not main_win or not vim.api.nvim_win_is_valid(main_win) or not win then
    self:close({ focus = false, layout = false })
    return false
  end
  width = math.max(1, width)
  height = math.max(1, math.min(height, MAX_VISIBLE_HEIGHT))
  vim.api.nvim_win_set_config(win, {
    relative = "win",
    win = main_win,
    row = math.max(0, row),
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    focusable = true,
    zindex = 53,
  })
  self:_render(width, height)
  return true
end

function InlineMenu:focus()
  if self:visible() then
    pcall(vim.api.nvim_set_current_win, self.win)
    vim.cmd("stopinsert")
    return true
  end
  return false
end

function InlineMenu:_changed(focus)
  self.deps.layout()
  if focus ~= false then
    self:focus()
  end
end

function InlineMenu:open(options)
  if self.destroyed then
    return { closed = true }
  end
  self:close({ focus = false, layout = false })
  self.generation = self.generation + 1
  local frame = self:_new_frame(options or {})
  self.stack = { frame }
  local surface = self:_make_surface(frame)
  self:_changed(true)
  return surface
end

function InlineMenu:push(options)
  if not self:active() or #self.stack >= MAX_DEPTH then
    local frame = self:_frame()
    if frame then
      frame.error = ("Menu depth is limited to %d"):format(MAX_DEPTH)
      self:_changed(true)
    end
    return nil
  end
  local frame = self:_new_frame(options or {})
  table.insert(self.stack, frame)
  local surface = self:_make_surface(frame)
  self:_changed(true)
  return surface
end

function InlineMenu:replace(options)
  if not self:active() then
    return self:open(options)
  end
  local previous = table.remove(self.stack)
  self:_mark_closed(previous)
  local frame = self:_new_frame(options or {})
  table.insert(self.stack, frame)
  local surface = self:_make_surface(frame)
  self:_changed(true)
  return surface
end

function InlineMenu:close(options)
  options = options or {}
  if self.closing then
    return
  end
  self.closing = true
  self.generation = self.generation + 1
  for _, frame in ipairs(self.stack) do
    self:_mark_closed(frame)
  end
  self.stack = {}
  if self:visible() then
    local win = self.win
    self.win = nil
    pcall(vim.api.nvim_win_close, win, true)
  else
    self.win = nil
  end
  self.closing = false
  if options.layout ~= false then
    self.deps.layout()
  end
  if options.focus ~= false and not self.destroyed then
    vim.schedule(function()
      if not self:active() and not self.destroyed then
        self.deps.focus_input()
      end
    end)
  end
end

function InlineMenu:back()
  if not self:active() then
    return false
  end
  if #self.stack > 1 then
    local frame = table.remove(self.stack)
    self:_mark_closed(frame)
    if frame.on_cancel then
      frame.on_cancel()
    end
    self:_changed(true)
  else
    local frame = self:_frame()
    local callback = frame and (frame.kind == "confirm" and frame.on_confirm or frame.on_cancel)
    local value = frame and frame.kind == "confirm" and false or nil
    self:close()
    if callback then
      callback(value)
    end
  end
  return true
end

function InlineMenu:cancel_group(return_to_editor)
  if not self:active() then
    return false
  end
  local frame = self:_frame()
  local callback = frame and (frame.kind == "confirm" and frame.on_confirm or frame.on_cancel)
  local value = frame and frame.kind == "confirm" and false or nil
  self:close({ focus = not return_to_editor })
  if callback then
    callback(value)
  end
  if return_to_editor then
    self.deps.return_to_editor()
  end
  return true
end

function InlineMenu:move(delta)
  local frame = self:_frame()
  if not frame or frame.kind == "input" or #frame.filtered == 0 then
    return false
  end
  frame.current = (frame.current - 1 + delta) % #frame.filtered + 1
  self:_changed(true)
  return true
end

function InlineMenu:insert(character)
  local frame = self:_frame()
  if not frame or vim.fn.strchars(frame.query) >= MAX_QUERY_CHARS then
    return false
  end
  frame.query = bounded_query(frame.query .. character)
  frame.first = 1
  self:_refresh(frame)
  self:_changed(true)
  return true
end

function InlineMenu:backspace()
  local frame = self:_frame()
  if not frame or frame.query == "" then
    return false
  end
  frame.query = vim.fn.strcharpart(frame.query, 0, math.max(0, vim.fn.strchars(frame.query) - 1))
  frame.first = 1
  self:_refresh(frame)
  self:_changed(true)
  return true
end

function InlineMenu:toggle()
  local frame = self:_frame()
  local row = frame and frame.filtered[frame.current]
  if not frame or frame.kind ~= "multi_select" or not row or row.kind then
    return false
  end
  frame.selected_keys[row.key] = not frame.selected_keys[row.key]
  self:_changed(true)
  return true
end

function InlineMenu:_load_more(frame, row)
  if frame.loading or type(frame.on_more) ~= "function" then
    return false
  end
  local cursor = row.kind == "retry" and frame.pending_cursor or frame.next_cursor
  frame.pending_cursor = cursor
  frame.loading = true
  frame.error = nil
  self:_refresh(frame)
  self:_changed(true)
  frame.on_more(cursor, frame.surface)
  return true
end

function InlineMenu:submit()
  local frame = self:_frame()
  if not frame then
    return false
  end
  if frame.kind == "input" then
    local callback = frame.on_submit or frame.on_select
    local value = frame.query
    if not frame.keep_open then
      self:close()
    end
    if callback then
      callback(value)
    end
    return true
  end

  local row = frame.filtered[frame.current]
  if not row then
    return false
  end
  if row.kind then
    return row.kind ~= "loading" and self:_load_more(frame, row) or false
  end
  if frame.kind == "multi_select" then
    local values = {}
    for _, item in ipairs(frame.items) do
      if frame.selected_keys[item.key] then
        table.insert(values, item.value)
      end
    end
    if #values == 0 and frame.on_empty then
      frame.error = nil
      frame.on_empty()
      self:_changed(true)
      return false
    end
    local callback = frame.on_select
    if not frame.keep_open then
      self:close()
    end
    if callback then
      callback(values)
    end
    return true
  end

  local callback = frame.kind == "confirm" and frame.on_confirm or frame.on_select
  local value = row.value
  if frame.kind == "confirm" then
    value = row.value.confirmed == true
  end
  if not frame.keep_open then
    self:close()
  end
  if callback then
    callback(value)
  end
  return true
end

function InlineMenu:_find_frame(surface)
  if not self:_surface_current(surface) then
    return nil
  end
  for _, frame in ipairs(self.stack) do
    if frame.id == surface.frame_id then
      return frame
    end
  end
end

function InlineMenu:_append(surface, items, next_cursor)
  local frame = self:_find_frame(surface)
  if not frame then
    return false
  end
  self:_add_items(frame, items)
  frame.next_cursor = next_cursor
  frame.pending_cursor = nil
  frame.loading = false
  frame.error = nil
  self:_refresh(frame)
  self:_changed(true)
  return true
end

function InlineMenu:_set_loading(surface, cursor)
  local frame = self:_find_frame(surface)
  if not frame or frame.loading then
    return false
  end
  frame.pending_cursor = cursor
  frame.loading = true
  frame.error = nil
  self:_refresh(frame)
  self:_changed(true)
  return true
end

function InlineMenu:_set_error(surface, message)
  local frame = self:_find_frame(surface)
  if not frame then
    return false
  end
  frame.loading = false
  frame.error = clean_line(message or "Unable to load more items")
  self:_refresh(frame)
  self:_changed(true)
  return true
end

function InlineMenu:destroy()
  if self.destroyed then
    return
  end
  self:close({ focus = false, layout = false })
  self.destroyed = true
  for _, autocmd in ipairs(self.autocmds) do
    pcall(vim.api.nvim_del_autocmd, autocmd)
  end
  self.autocmds = {}
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

M.InlineMenu = InlineMenu
M.limits = {
  depth = MAX_DEPTH,
  items = MAX_ITEMS,
  query_chars = MAX_QUERY_CHARS,
  line_chars = MAX_LINE_CHARS,
  visible_height = MAX_VISIBLE_HEIGHT,
}
return M
