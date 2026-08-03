local config = require("pi.config")
local renderer = require("pi.ui.render")
local image_data = require("pi.ui.image")
local markdown_image = require("pi.ui.markdown_image")
local input_area = require("pi.ui.input")

local namespace = vim.api.nvim_create_namespace("pi.nvim")
local TranscriptView = {}
TranscriptView.__index = TranscriptView

function TranscriptView.new(deps)
  local self = setmetatable({
    root = deps.root,
    output = deps.output,
    image_backend = deps.image_backend,
    ui_group = deps.ui_group,
    window_provider = deps.window,
    items_provider = deps.items,
    state_provider = deps.state,
    widget_content = deps.widget_content,
    permission_content = deps.permission_content,
    body_bytes_provider = deps.body_bytes,
    materialize = deps.materialize,
    process_active = deps.process_active or function()
      return false
    end,
    track_image = deps.track_image,
    refresh_image_accounting = deps.refresh_image_accounting,
    actions = deps.actions,
    buf = nil,
    render_pending = false,
    render_timer = nil,
    render_cache = nil,
    render_frame = nil,
    render_cache_bytes = 0,
    render_frame_bytes = 0,
    projection_retained_bytes = 0,
    prepared_images_width = nil,
    tool_ranges = {},
    process_ranges = {},
    image_placements = {},
  }, TranscriptView)
  return self
end

function TranscriptView:window()
  return self.window_provider()
end

function TranscriptView:items()
  return self.items_provider()
end

function TranscriptView:state()
  return self.state_provider()
end

function TranscriptView:body_bytes()
  return self.body_bytes_provider()
end

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

local function render_projection_bytes(result)
  local total = 0
  for _, line in ipairs((result and result.lines) or {}) do
    total = total + #line
  end
  for _, mark in ipairs((result and result.marks) or {}) do
    total = total + #(mark.highlight or "") + #(mark.line_highlight or "")
  end
  for _, image in ipairs((result and result.images) or {}) do
    total = total + #(image.key or "") + #(image.content_key or "") + #(image.path or "")
  end
  return total
end

local function dynamic_projection_bytes(lines, marks_by_row)
  local total = 0
  for _, line in ipairs(lines or {}) do
    total = total + #line
  end
  for _, marks in pairs(marks_by_row or {}) do
    for _, mark in ipairs(marks) do
      total = total + #(mark.highlight or "") + #(mark.line_highlight or "")
    end
  end
  return total
end

function TranscriptView:_ensure_buffer()
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
    group = self.ui_group,
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
    self.actions.close()
  end, { buffer = self.buf, silent = true })
  for _, key in ipairs({ "i", "a" }) do
    vim.keymap.set("n", key, function()
      self.actions.focus_input()
    end, { buffer = self.buf, silent = true })
  end
  vim.keymap.set("n", "<C-c>", function()
    self.actions.abort()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-l>", function()
    self.actions.select_model()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    self.actions.cycle_model()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    self.actions.cycle_thinking_level()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-o>", function()
    self.actions.toggle_tools()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-t>", function()
    self.actions.toggle_thinking()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-x>", function()
    self.actions.copy_last_assistant()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function()
    self.actions.left_mouse()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<CR>", function()
    local descriptor = self:image_at_row(vim.api.nvim_win_get_cursor(self:window())[1])
    if descriptor then
      self.actions.open_image_preview(descriptor)
    else
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    end
  end, { buffer = self.buf, silent = true })
  return self.buf
end

function TranscriptView:_with_modifiable(callback)
  local buf = self:_ensure_buffer()
  vim.bo[buf].modifiable = true
  callback(buf)
  vim.bo[buf].modifiable = false
end

function TranscriptView:_clamp_transcript_view()
  if
    not self:window()
    or not vim.api.nvim_win_is_valid(self:window())
    or not self.buf
    or not vim.api.nvim_buf_is_valid(self.buf)
    or vim.api.nvim_win_get_buf(self:window()) ~= self.buf
  then
    return false
  end

  local clamped = false
  vim.api.nvim_win_call(self:window(), function()
    local last_line = vim.api.nvim_buf_line_count(self.buf)
    if vim.fn.line("w$") ~= last_line then
      return
    end

    local position = vim.fn.screenpos(self:window(), last_line, 1)
    local window_position = vim.fn.win_screenpos(self:window())
    local relative_row = position.row - window_position[1] + 1
    local view = vim.fn.winsaveview()
    local has_scrolled_origin = view.topline > 1 or (view.skipcol or 0) > 0
    if position.row > 0 and relative_row < vim.api.nvim_win_get_height(self:window()) and has_scrolled_origin then
      vim.cmd("normal! Gzb")
      clamped = true
    end
  end)
  return clamped
end

function TranscriptView:_render_transcript()
  self.materialize()
  local follow_output = true
  local previous_row = 1
  if
    self:window()
    and vim.api.nvim_win_is_valid(self:window())
    and self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
  then
    previous_row = vim.api.nvim_win_get_cursor(self:window())[1]
    follow_output = previous_row >= vim.api.nvim_buf_line_count(self.buf) - 1
  end

  local width = self:window() and vim.api.nvim_win_is_valid(self:window()) and vim.api.nvim_win_get_width(self:window())
    or 80
  local process_active = self.process_active()
  local stable_count = #self:items()
  if #self:items() > 0 and (process_active or self:items()[#self:items()].type == "user") then
    stable_count = 0
    for index = #self:items(), 1, -1 do
      if self:items()[index].type == "user" then
        stable_count = index - 1
        break
      end
    end
  end

  local image_terminal = self.image_backend and self.image_backend:is_terminal() or false
  local security_mode = (config.get().security or {}).mode
  local cache_key = table.concat({
    tostring(width),
    tostring(self:state().hide_thinking),
    tostring(self:state().tools_expanded),
    tostring(self:state().process_expanded),
    tostring(image_terminal),
    tostring(self.root),
    tostring(self:state().model),
    tostring(self:state().thinking),
    tostring(self:state().permission_mode or "syncing"),
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
    hide_thinking = self:state().hide_thinking,
    tools_expanded = self:state().tools_expanded,
    collapse_processes = true,
    process_expanded = self:state().process_expanded,
    image_terminal = image_terminal,
    root = self.root,
    width = width,
  }
  local prefix
  local cache_reused = false
  local cache_candidate
  if self.render_cache and self.render_cache.key == cache_key and self.render_cache.count == stable_count then
    prefix = self.render_cache.result
    cache_reused = true
  else
    local prefix_opts = vim.tbl_extend("force", {}, base_opts, {
      process_active = false,
      welcome = {
        model = self:state().model,
        thinking = self:state().thinking,
        root = self.root,
        permission = self:state().permission_mode or "syncing",
        security = security_mode,
      },
    })
    prefix = render_result(slice(self:items(), 1, stable_count), prefix_opts)
    local cached_items = {}
    for index = 1, stable_count do
      cached_items[self:items()[index]] = true
    end
    cache_candidate = {
      key = cache_key,
      count = stable_count,
      items = cached_items,
      result = prefix,
      retained_bytes = render_projection_bytes(prefix),
    }
  end

  local tail = nil
  if stable_count < #self:items() then
    tail = render_result(
      slice(self:items(), stable_count + 1, #self:items()),
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
  local dynamic_marks = tail and offset_marks(tail.marks, separator) or {}
  local widget_lines, widget_marks = self.widget_content(width)
  if #widget_lines > 0 then
    local previous_line = dynamic_lines[#dynamic_lines] or prefix.lines[#prefix.lines]
    if previous_line and previous_line ~= "" then
      table.insert(dynamic_lines, "")
    end
    local widget_offset = #dynamic_lines
    vim.list_extend(dynamic_lines, widget_lines)
    vim.list_extend(dynamic_marks, offset_marks(widget_marks, widget_offset))
  end
  local permission_lines, permission_marks = self.permission_content(width)
  if #permission_lines > 0 then
    local previous_line = dynamic_lines[#dynamic_lines] or prefix.lines[#prefix.lines]
    if previous_line and previous_line ~= "" then
      table.insert(dynamic_lines, "")
    end
    local permission_offset = #dynamic_lines
    vim.list_extend(dynamic_lines, permission_lines)
    vim.list_extend(dynamic_marks, offset_marks(permission_marks, permission_offset))
  end
  for _ = 1, self:state().overlay_height or 0 do
    table.insert(dynamic_lines, "")
  end
  if prefix_rows == 0 and #dynamic_lines == 0 then
    dynamic_lines = { "" }
  end
  self.tool_ranges = merge_ranges(prefix.tool_ranges, tail and tail.tool_ranges, tail_offset)
  self.process_ranges = merge_ranges(prefix.process_ranges, tail and tail.process_ranges, tail_offset)
  self.image_placements = merge_images(prefix.images, tail and tail.images, tail_offset)
  local total_lines = prefix_rows + #dynamic_lines

  local dynamic_row_marks = effective_marks_by_row(dynamic_marks)
  local previous_frame = self.render_frame
  self:_with_modifiable(function(buf)
    local old = previous_frame
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
  local frame_candidate = {
    prefix = prefix,
    prefix_rows = prefix_rows,
    dynamic_lines = vim.list_slice(dynamic_lines),
    dynamic_row_marks = dynamic_row_marks,
    total_lines = total_lines,
  }
  frame_candidate.retained_bytes = dynamic_projection_bytes(frame_candidate.dynamic_lines, dynamic_row_marks)
  local retained_cache = cache_reused and self.render_cache or cache_candidate
  local cache_bytes = retained_cache and retained_cache.retained_bytes or 0
  local body_bytes = self:body_bytes()
  local maximum = self.output.transcript_max_bytes
  if body_bytes + cache_bytes <= maximum then
    self.render_cache = retained_cache
    self.render_cache_bytes = cache_bytes
    if body_bytes + cache_bytes + frame_candidate.retained_bytes <= maximum then
      self.render_frame = frame_candidate
      self.render_frame_bytes = frame_candidate.retained_bytes
    else
      self.render_frame = nil
      self.render_frame_bytes = 0
    end
  else
    self.render_cache = nil
    self.render_frame = nil
    self.render_cache_bytes = 0
    self.render_frame_bytes = 0
  end
  self.projection_retained_bytes = (self.render_cache_bytes or 0) + (self.render_frame_bytes or 0)
  if self.image_backend then
    self.image_backend:sync(self.buf, self:window(), self.image_placements)
  end

  if self:window() and vim.api.nvim_win_is_valid(self:window()) then
    local row = follow_output and total_lines or math.min(previous_row, total_lines)
    vim.api.nvim_win_set_cursor(self:window(), { math.max(1, row), 0 })
  end
end

function TranscriptView:_prepare_images(width, start_index, prepare_preview)
  local seen = {}
  local function prepare(content, include_markdown, item)
    if type(content) ~= "table" then
      return
    end
    local function prepare_block(block)
      if block.type == "image" and not seen[block] then
        seen[block] = true
        self.track_image(block)
        local prepared = image_data.prepare(block, width - 6)
        local retained = self.refresh_image_accounting(item, block)
        if prepared and prepare_preview and retained then
          image_data.prepare_preview(block, function()
            self.refresh_image_accounting(item, block)
            self:invalidate()
            self:schedule_render()
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
  for index = math.max(1, start_index or 1), #self:items() do
    local item = self:items()[index]
    if item.type == "user" then
      prepare(item.content, false, item)
    elseif item.type == "assistant" then
      prepare(item.message and item.message.content, true, item)
    elseif item.type == "tool" then
      prepare(item.result and item.result.content, false, item)
    end
  end
end

function TranscriptView:_schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  local interval = math.max(50, self.output.render_interval_ms)
  self.render_timer = vim.defer_fn(function()
    self.render_pending = false
    self.render_timer = nil
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      self:_render_transcript()
    end
  end, interval)
end

function TranscriptView:_tool_at_row(row)
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

function TranscriptView:_process_at_row(row)
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

function TranscriptView:_image_at_row(row)
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

function TranscriptView:_image_at_mouse(mouse)
  local win = self:window()
  if not win or not vim.api.nvim_win_is_valid(win) or not mouse or tonumber(mouse.winid) ~= win then
    return nil
  end
  local screen_row = tonumber(mouse.screenrow)
  local screen_col = tonumber(mouse.screencol)
  if screen_row and screen_col then
    for index = #(self.image_placements or {}), 1, -1 do
      local descriptor = self.image_placements[index]
      local position = vim.fn.screenpos(win, descriptor.row + 1, descriptor.col + 1)
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

function TranscriptView:invalidate()
  self.render_cache = nil
  self.render_cache_bytes = 0
  self.projection_retained_bytes = self.render_frame_bytes or 0
end

function TranscriptView:invalidate_item(item)
  if self.render_cache and self.render_cache.items[item] then
    self:invalidate()
  end
end

function TranscriptView:clear()
  self.render_cache = nil
  self.render_frame = nil
  self.render_cache_bytes = 0
  self.render_frame_bytes = 0
  self.projection_retained_bytes = 0
  self.prepared_images_width = nil
  self.tool_ranges = {}
  self.process_ranges = {}
  self.image_placements = {}
end

function TranscriptView:projection_bytes()
  return self.projection_retained_bytes or 0
end

function TranscriptView:buffer()
  return self.buf
end

function TranscriptView:ensure_buffer()
  return self:_ensure_buffer()
end

function TranscriptView:has_buffer()
  return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
end

function TranscriptView:set_image_backend(backend)
  self.image_backend = backend
end

function TranscriptView:clear_images()
  if self.image_backend and self.buf then
    self.image_backend:clear(self.buf)
  end
end

function TranscriptView:update_layout_width(width)
  local changed = self.layout_width ~= width
  self.layout_width = width
  return changed
end

function TranscriptView:reset_layout_width()
  self.layout_width = nil
end

function TranscriptView:set_title(title)
  if not self:has_buffer() then
    return
  end
  vim.b[self.buf].pi_title = title
  local label = ("Pi · %s · %s"):format(title, vim.fs.basename(self.root))
  if not pcall(vim.api.nvim_buf_set_name, self.buf, label) then
    pcall(vim.api.nvim_buf_set_name, self.buf, label .. " · " .. vim.fn.sha256(self.root):sub(1, 6))
  end
end

function TranscriptView:owns_buffer(bufnr)
  return bufnr ~= nil and self.buf == bufnr
end

function TranscriptView:render()
  return self:_render_transcript()
end

function TranscriptView:clamp()
  return self:_clamp_transcript_view()
end

function TranscriptView:schedule_render()
  return self:_schedule_render()
end

function TranscriptView:tool_at_row(row)
  return self:_tool_at_row(row)
end

function TranscriptView:process_at_row(row)
  return self:_process_at_row(row)
end

function TranscriptView:image_at_row(row)
  return self:_image_at_row(row)
end

function TranscriptView:image_at_mouse(mouse)
  return self:_image_at_mouse(mouse)
end

function TranscriptView:destroy()
  if self.render_timer then
    self.render_timer:stop()
    self.render_timer:close()
    self.render_timer = nil
  end
  self.render_pending = false
  if self.image_backend and self.buf then
    self.image_backend:clear(self.buf)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
  self:clear()
end

return { TranscriptView = TranscriptView }
