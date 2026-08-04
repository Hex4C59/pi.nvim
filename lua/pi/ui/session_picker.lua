local truncate_display = require("pi.format").truncate_display

local M = {}
local group = vim.api.nvim_create_augroup("PiNvimSessionPicker", { clear = false })
local namespace = vim.api.nvim_create_namespace("pi.nvim.session_picker")

local function geometry(line_count)
  local columns = math.max(1, vim.o.columns)
  local reserved_rows = math.max(1, vim.o.cmdheight) + (vim.o.laststatus == 0 and 0 or 1)
  local usable_rows = math.max(1, vim.o.lines - reserved_rows)
  if columns < 48 or usable_rows < 10 then
    return nil
  end
  local width = math.min(columns - 2, math.max(46, math.floor(columns * 0.72)))
  local height = math.min(usable_rows - 2, math.max(6, math.min(line_count, math.floor(usable_rows * 0.6))))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((usable_rows - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
  }
end

local function session_label(session, width)
  local title = session.name or session.preview or session.id or session.path or "Unnamed session"
  title = tostring(title):gsub("%s+", " ")
  local details = {}
  table.insert(details, ("%d msgs"):format(tonumber(session.messageCount) or 0))
  if session.model and session.model.provider and session.model.id then
    table.insert(details, session.model.provider .. "/" .. session.model.id)
  end
  if session.updatedAt then
    table.insert(details, tostring(session.updatedAt):gsub("T", " "):sub(1, 16))
  end
  local suffix = table.concat(details, " | ")
  local suffix_width = vim.fn.strdisplaywidth(suffix)
  local title_width = math.max(1, width - suffix_width - 3)
  return truncate_display(title, title_width) .. " | " .. suffix
end

local function configure_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "text"
  vim.b[buf].pi_kind = "session_picker"
end

local function rows_for(picker)
  local rows = {}
  for _, session in ipairs(picker.sessions) do
    table.insert(rows, { kind = "session", session = session })
  end
  if picker.loading then
    table.insert(rows, { kind = "loading" })
  elseif picker.error then
    table.insert(rows, { kind = "retry", cursor = picker.pending_cursor })
  elseif picker.next_cursor then
    table.insert(rows, { kind = "more", cursor = picker.next_cursor })
  end
  table.insert(rows, { kind = "path" })
  return rows
end

local function row_label(row, width)
  if row.kind == "session" then
    return session_label(row.session, width)
  elseif row.kind == "loading" then
    return "Loading more sessions..."
  elseif row.kind == "retry" then
    return "Retry loading more sessions"
  elseif row.kind == "more" then
    return "Load more sessions"
  end
  return "Enter a session path..."
end

local function render(picker)
  if picker.closed or not vim.api.nvim_buf_is_valid(picker.buf) then
    return
  end
  picker.rows = rows_for(picker)
  picker.selected = math.max(1, math.min(picker.selected, #picker.rows))
  local width = math.max(1, picker.width - 4)
  local lines = {}
  for index, row in ipairs(picker.rows) do
    local prefix = index == picker.selected and "> " or "  "
    table.insert(lines, prefix .. truncate_display(row_label(row, width), width))
  end
  vim.bo[picker.buf].modifiable = true
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  vim.bo[picker.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(picker.buf, namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(picker.buf, namespace, picker.selected - 1, 0, {
    end_row = picker.selected,
    hl_group = "Visual",
    hl_eol = true,
  })
  if vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_win_set_cursor(picker.win, { picker.selected, 0 })
  end
end

function M.open(options)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  configure_buffer(buf)
  local layout = geometry(#(options.sessions or {}) + 2)
  local floating = layout ~= nil
  local win
  if floating then
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = "Pi sessions",
      title_pos = "center",
      width = layout.width,
      height = layout.height,
      row = layout.row,
      col = layout.col,
    })
  else
    win = previous_win
    vim.api.nvim_win_set_buf(win, buf)
  end

  local picker = {
    buf = buf,
    win = win,
    width = floating and layout.width or math.max(1, vim.api.nvim_win_get_width(win)),
    floating = floating,
    previous_win = previous_win,
    previous_buf = previous_buf,
    previous_wrap = vim.wo[win].wrap,
    previous_cursorline = vim.wo[win].cursorline,
    sessions = {},
    paths = {},
    next_cursor = options.next_cursor,
    pending_cursor = nil,
    loading = false,
    error = nil,
    selected = 1,
    rows = {},
    autocmds = {},
    closed = false,
  }

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  function picker:close()
    if self.closed then
      return
    end
    self.closed = true
    for _, autocmd in ipairs(self.autocmds) do
      pcall(vim.api.nvim_del_autocmd, autocmd)
    end
    self.autocmds = {}
    local restore_focus = vim.api.nvim_get_current_win() == self.win
    if self.floating and vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_win_close(self.win, true)
    elseif vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf then
      if vim.api.nvim_buf_is_valid(self.previous_buf) then
        vim.api.nvim_win_set_buf(self.win, self.previous_buf)
      end
    end
    if not self.floating and vim.api.nvim_win_is_valid(self.win) then
      vim.wo[self.win].wrap = self.previous_wrap
      vim.wo[self.win].cursorline = self.previous_cursorline
    end
    if vim.api.nvim_buf_is_valid(self.buf) then
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
    if restore_focus and vim.api.nvim_win_is_valid(self.previous_win) then
      vim.api.nvim_set_current_win(self.previous_win)
    end
  end

  function picker:append(sessions, next_cursor)
    if self.closed then
      return
    end
    for _, session in ipairs(sessions or {}) do
      if session.path and not self.paths[session.path] then
        self.paths[session.path] = true
        table.insert(self.sessions, session)
      end
    end
    self.next_cursor = next_cursor
    self.pending_cursor = nil
    self.loading = false
    self.error = nil
    render(self)
  end

  function picker:set_loading(cursor)
    if self.closed or self.loading then
      return false
    end
    self.pending_cursor = cursor
    self.loading = true
    self.error = nil
    render(self)
    return true
  end

  function picker:set_error(message)
    if self.closed then
      return
    end
    self.loading = false
    self.error = message or "Unable to load sessions"
    render(self)
  end

  local function cancel()
    if picker.closed then
      return
    end
    picker:close()
    if options.on_cancel then
      options.on_cancel()
    end
  end

  local function move(delta)
    if picker.closed or #picker.rows == 0 then
      return
    end
    picker.selected = (picker.selected - 1 + delta) % #picker.rows + 1
    render(picker)
  end

  local function submit()
    if picker.closed then
      return
    end
    local row = picker.rows[picker.selected]
    if not row or row.kind == "loading" then
      return
    elseif row.kind == "session" then
      picker:close()
      options.on_select(row.session)
    elseif row.kind == "path" then
      picker:close()
      options.on_path()
    elseif picker:set_loading(row.cursor) then
      options.on_more(row.cursor, picker)
    end
  end

  for _, key in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", key, function()
      move(1)
    end, { buffer = buf, silent = true })
  end
  for _, key in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", key, function()
      move(-1)
    end, { buffer = buf, silent = true })
  end
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, cancel, { buffer = buf, silent = true })
  end
  table.insert(
    picker.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = cancel,
    })
  )
  table.insert(
    picker.autocmds,
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = group,
      buffer = buf,
      once = true,
      callback = cancel,
    })
  )
  picker:append(options.sessions, options.next_cursor)
  return picker
end

return M
