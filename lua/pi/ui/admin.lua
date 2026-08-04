local dialog_surface = require("pi.ui.dialog_surface")
local truncate_display = require("pi.format").truncate_display

local M = {}
local group = vim.api.nvim_create_augroup("PiNvimAdministrativeUI", { clear = false })
local namespace = vim.api.nvim_create_namespace("pi.nvim.administrative_ui")

local function close_then(surface_ref, callback, value)
  local active = surface_ref[1]
  if active then
    active:close()
  end
  if callback then
    callback(value)
  end
end

function M.select(options)
  local items = options.items or {}
  local labels = {}
  local by_label = {}
  for index, item in ipairs(items) do
    local label = options.format_item and options.format_item(item) or tostring(item)
    if by_label[label] then
      label = ("%s [%d]"):format(label, index)
    end
    labels[index] = label
    by_label[label] = item
  end
  local surface_ref = {}
  surface_ref[1] = dialog_surface.open({
    method = "select",
    title = options.title or "Pi",
    options = labels,
  }, function(response)
    close_then(surface_ref, options.on_select, by_label[response.value])
  end, function()
    close_then(surface_ref, options.on_cancel)
  end)
  return surface_ref[1]
end

function M.confirm(options)
  local surface_ref = {}
  surface_ref[1] = dialog_surface.open({
    method = "confirm",
    title = options.title or "Pi",
    message = options.message or "",
  }, function(response)
    close_then(surface_ref, options.on_confirm, response.confirmed == true)
  end, function()
    close_then(surface_ref, options.on_confirm, false)
  end)
  return surface_ref[1]
end

function M.input(options)
  local surface_ref = {}
  surface_ref[1] = dialog_surface.open({
    method = "input",
    title = options.title or "Pi",
    placeholder = options.placeholder,
    sensitive = options.sensitive == true,
  }, function(response)
    close_then(surface_ref, options.on_submit, response.value)
  end, function()
    close_then(surface_ref, options.on_cancel)
  end)
  return surface_ref[1]
end

local function tabline_height()
  if vim.o.showtabline == 2 then
    return 1
  end
  return vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1 and 1 or 0
end

local function geometry(line_count)
  local columns = math.max(1, vim.o.columns)
  local reserved = math.max(1, vim.o.cmdheight) + (vim.o.laststatus == 0 and 0 or 1) + tabline_height()
  local rows = math.max(1, vim.o.lines - reserved)
  if columns < 48 or rows < 10 then
    return nil
  end
  local width = math.min(columns - 2, math.max(46, math.floor(columns * 0.7)))
  local height = math.min(rows - 2, math.max(6, math.min(line_count + 2, math.floor(rows * 0.7))))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
  }
end

local function open_scratch(title, lines, filetype, kind)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].filetype = filetype
  vim.b[buf].pi_kind = kind
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local layout = geometry(#lines)
  local floating = layout ~= nil
  local win
  if floating then
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = truncate_display(title, math.max(1, layout.width - 2)),
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

  local controller = {
    buf = buf,
    win = win,
    floating = floating,
    previous_win = previous_win,
    previous_buf = previous_buf,
    previous_wrap = vim.wo[win].wrap,
    previous_cursorline = vim.wo[win].cursorline,
    autocmds = {},
    closed = false,
  }

  function controller:close()
    if self.closed then
      return
    end
    self.closed = true
    for _, id in ipairs(self.autocmds) do
      pcall(vim.api.nvim_del_autocmd, id)
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

  table.insert(
    controller.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function()
        controller:close()
      end,
    })
  )
  table.insert(
    controller.autocmds,
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        controller:close()
      end,
    })
  )
  return controller
end

local function model_key(model)
  return model.provider .. "\0" .. model.id
end

function M.multi_select(options)
  local items = options.items or {}
  local selected = {}
  for _, item in ipairs(options.selected or {}) do
    selected[model_key(item)] = true
  end
  local initial_lines = #items > 0 and vim.tbl_map(function()
    return ""
  end, items) or { "No models available" }
  local picker = open_scratch(options.title or "Pi model scope", initial_lines, "pi_admin_select", "admin_select")
  picker.items = items
  picker.selected = selected
  picker.cursor = 1
  picker.cancelled = false
  picker.on_cancel = options.on_cancel

  function picker:render()
    if self.closed or not vim.api.nvim_buf_is_valid(self.buf) then
      return
    end
    local width = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or vim.o.columns
    local lines = {}
    for _, item in ipairs(self.items) do
      local marker = self.selected[model_key(item)] and "[x] " or "[ ] "
      table.insert(lines, truncate_display(marker .. item.provider .. "/" .. item.id, math.max(1, width - 1)))
    end
    if #lines == 0 then
      lines = { "No models available" }
    end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
    if #self.items > 0 then
      vim.api.nvim_buf_set_extmark(self.buf, namespace, self.cursor - 1, 0, {
        end_row = self.cursor,
        hl_group = "Visual",
        hl_eol = true,
      })
      if vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_set_cursor(self.win, { self.cursor, 0 })
      end
    end
  end

  local function move(delta)
    if #picker.items > 0 and not picker.closed then
      picker.cursor = (picker.cursor - 1 + delta) % #picker.items + 1
      picker:render()
    end
  end
  local function toggle()
    local item = picker.items[picker.cursor]
    if item and not picker.closed then
      local key = model_key(item)
      picker.selected[key] = not picker.selected[key]
      picker:render()
    end
  end
  local function toggle_all()
    if picker.closed or #picker.items == 0 then
      return
    end
    local all = true
    for _, item in ipairs(picker.items) do
      all = all and picker.selected[model_key(item)] == true
    end
    for _, item in ipairs(picker.items) do
      picker.selected[model_key(item)] = not all
    end
    picker:render()
  end
  local function submit()
    if picker.closed or #picker.items == 0 then
      return
    end
    local result = {}
    for _, item in ipairs(picker.items) do
      if picker.selected[model_key(item)] then
        table.insert(result, item)
      end
    end
    if #result == 0 and options.on_empty then
      options.on_empty()
      return
    end
    picker:close()
    if options.on_select then
      options.on_select(result)
    end
  end
  local function cancel()
    if picker.closed then
      return
    end
    picker.cancelled = true
    picker:close()
    if options.on_cancel then
      options.on_cancel()
    end
  end
  for _, key in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", key, function()
      move(1)
    end, { buffer = picker.buf, silent = true })
  end
  for _, key in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", key, function()
      move(-1)
    end, { buffer = picker.buf, silent = true })
  end
  vim.keymap.set("n", "<Space>", toggle, { buffer = picker.buf, silent = true })
  vim.keymap.set("n", "a", toggle_all, { buffer = picker.buf, silent = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = picker.buf, silent = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, cancel, { buffer = picker.buf, silent = true })
  end
  picker:render()
  return picker
end

return M
