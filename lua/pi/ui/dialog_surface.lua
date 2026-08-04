local truncate_display = require("pi.format").truncate_display

local M = {}
local group = vim.api.nvim_create_augroup("PiNvimExtensionDialogs", { clear = false })
local namespace = vim.api.nvim_create_namespace("pi.nvim.extension_dialog")
local sensitive_surfaces = {}
local paste_handler
local previous_paste_handler

local function active_sensitive_surface()
  local current_buf = vim.api.nvim_get_current_buf()
  for index = #sensitive_surfaces, 1, -1 do
    local candidate = sensitive_surfaces[index]
    if not candidate.closed and candidate.buf == current_buf then
      return candidate
    end
  end
end

local function install_sensitive_paste(surface)
  if #sensitive_surfaces == 0 then
    local inherited = vim.paste
    previous_paste_handler = inherited
    paste_handler = function(lines, phase)
      local active = vim.fn.getcmdtype() == "" and active_sensitive_surface() or nil
      if active then
        return active:capture_paste(lines, phase)
      end
      return inherited(lines, phase)
    end
    vim.paste = paste_handler
  end
  table.insert(sensitive_surfaces, surface)
end

local function remove_sensitive_paste(surface)
  for index = #sensitive_surfaces, 1, -1 do
    if sensitive_surfaces[index] == surface then
      table.remove(sensitive_surfaces, index)
      break
    end
  end
  if #sensitive_surfaces == 0 then
    if vim.paste == paste_handler then
      vim.paste = previous_paste_handler
    end
    paste_handler = nil
    previous_paste_handler = nil
  end
end

local function tabline_height()
  if vim.o.showtabline == 2 then
    return 1
  end
  return vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1 and 1 or 0
end

local function geometry(kind, line_count)
  local columns = math.max(1, vim.o.columns)
  local statusline = vim.o.laststatus == 0 and 0 or 1
  local reserved_rows = math.max(1, vim.o.cmdheight) + statusline + tabline_height()
  local usable_rows = math.max(1, vim.o.lines - reserved_rows)
  local maximum_width = math.max(1, columns - 2)
  local maximum_height = math.max(1, usable_rows - 2)
  local minimum_height = kind == "editor" and 8 or 4
  if maximum_width < 40 or maximum_height < minimum_height then
    return nil
  end

  local desired_height
  if kind == "editor" then
    desired_height = math.max(8, math.min(line_count + 4, math.floor(usable_rows * 0.6)))
  else
    desired_height = math.max(4, math.min(line_count + 2, math.floor(usable_rows * 0.5)))
  end
  local width = math.min(maximum_width, math.max(40, math.floor(columns * 0.65)))
  local height = math.min(maximum_height, desired_height)
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((usable_rows - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
  }
end

local function request_lines(request)
  if request.method == "editor" then
    return vim.split(request.prefill or "", "\n", { plain = true })
  elseif request.method == "input" then
    return { "" }
  elseif request.method == "confirm" then
    local lines = vim.split(request.message or "", "\n", { plain = true })
    if #lines == 1 and lines[1] == "" then
      lines = {}
    end
    table.insert(lines, "")
    table.insert(lines, "No")
    table.insert(lines, "Yes")
    return lines
  end

  local lines = {}
  for _, option in ipairs(request.options or {}) do
    table.insert(lines, tostring(option))
  end
  return lines
end

local function configure_buffer(buf, request, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].filetype = request.method == "editor" and "markdown" or "text"
  vim.b[buf].pi_kind = "extension_dialog"
  vim.b[buf].pi_sensitive = request.sensitive == true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function render_choices(surface)
  local request = surface.request
  local values
  local offset = 0
  if request.method == "confirm" then
    values = { "No", "Yes" }
    offset = vim.api.nvim_buf_line_count(surface.buf) - #values
  else
    values = request.options or {}
  end

  local width = surface.width or math.max(1, vim.o.columns)
  local lines = {}
  if offset > 0 then
    lines = vim.api.nvim_buf_get_lines(surface.buf, 0, offset, false)
  end
  for index, value in ipairs(values) do
    local prefix = index == surface.selected and "> " or "  "
    table.insert(lines, prefix .. truncate_display(tostring(value), math.max(1, width - 4)))
  end
  vim.bo[surface.buf].modifiable = true
  vim.api.nvim_buf_set_lines(surface.buf, 0, -1, false, lines)
  vim.bo[surface.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(surface.buf, namespace, 0, -1)
  if #values > 0 then
    vim.api.nvim_buf_set_extmark(surface.buf, namespace, offset + surface.selected - 1, 0, {
      end_row = offset + surface.selected,
      hl_group = "Visual",
      hl_eol = true,
    })
  end
end

local function update_placeholder(surface)
  vim.api.nvim_buf_clear_namespace(surface.buf, namespace, 0, -1)
  local line = vim.api.nvim_buf_get_lines(surface.buf, 0, 1, false)[1] or ""
  if line == "" and surface.request.placeholder and surface.request.placeholder ~= "" then
    vim.api.nvim_buf_set_extmark(surface.buf, namespace, 0, 0, {
      virt_text = { { surface.request.placeholder, "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

local function install_lifecycle(surface)
  table.insert(
    surface.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(surface.win),
      once = true,
      callback = function()
        if not surface.closed then
          surface.on_cancel()
        end
      end,
    })
  )
  table.insert(
    surface.autocmds,
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = group,
      buffer = surface.buf,
      once = true,
      callback = function()
        if not surface.closed then
          surface.on_cancel()
        end
      end,
    })
  )
end

local function install_choice_mappings(surface)
  local request = surface.request
  local count = request.method == "confirm" and 2 or #(request.options or {})
  local function select(delta)
    if surface.closed or count == 0 then
      return
    end
    surface.selected = (surface.selected - 1 + delta) % count + 1
    render_choices(surface)
  end
  local function submit()
    if surface.closed or count == 0 then
      return
    end
    if request.method == "confirm" then
      surface.on_submit({ confirmed = surface.selected == 2 })
    else
      surface.on_submit({ value = request.options[surface.selected] })
    end
  end
  for _, key in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", key, function()
      select(1)
    end, { buffer = surface.buf, silent = true })
  end
  for _, key in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", key, function()
      select(-1)
    end, { buffer = surface.buf, silent = true })
  end
  vim.keymap.set("n", "<CR>", submit, { buffer = surface.buf, silent = true })
  if request.method == "confirm" then
    vim.keymap.set("n", "y", function()
      surface.on_submit({ confirmed = true })
    end, { buffer = surface.buf, silent = true })
    vim.keymap.set("n", "n", function()
      surface.on_submit({ confirmed = false })
    end, { buffer = surface.buf, silent = true })
  end
  render_choices(surface)
end

local function install_text_mappings(surface)
  local request = surface.request
  local function submit()
    local value
    if request.sensitive then
      value = surface.secret or ""
    else
      local lines = vim.api.nvim_buf_get_lines(surface.buf, 0, -1, false)
      value = request.method == "input" and (lines[1] or "") or table.concat(lines, "\n")
    end
    surface.on_submit({ value = value })
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = surface.buf, silent = true })
  if request.method == "input" then
    vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = surface.buf, silent = true })
    if request.sensitive then
      vim.bo[surface.buf].undolevels = -1
      table.insert(
        surface.autocmds,
        vim.api.nvim_create_autocmd("InsertCharPre", {
          group = group,
          buffer = surface.buf,
          callback = function()
            if not surface.closed and vim.v.char ~= "" then
              vim.v.char = surface:capture_secret(vim.v.char)
            end
          end,
        })
      )
      table.insert(
        surface.autocmds,
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
          group = group,
          buffer = surface.buf,
          callback = function()
            if surface.closed or surface.secret_syncing then
              return
            end
            local line = vim.api.nvim_buf_get_lines(surface.buf, 0, 1, false)[1] or ""
            local display_length = line:match("^%**$") and vim.fn.strchars(line) or -1
            local secret_length = vim.fn.strchars(surface.secret or "")
            if display_length >= 0 and display_length <= secret_length then
              surface.secret = vim.fn.strcharpart(surface.secret or "", 0, display_length)
            else
              surface:render_secret()
            end
            update_placeholder(surface)
          end,
        })
      )
      for _, key in ipairs({ "<Left>", "<Right>", "<Up>", "<Down>", "<Home>", "<Del>", "<C-o>", "<C-r>" }) do
        vim.keymap.set("i", key, "<Nop>", { buffer = surface.buf, silent = true })
      end
      for _, key in ipairs({ "<Esc>", "<C-[>" }) do
        vim.keymap.set("i", key, surface.on_cancel, { buffer = surface.buf, silent = true })
      end
    else
      table.insert(
        surface.autocmds,
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
          group = group,
          buffer = surface.buf,
          callback = function()
            if not surface.closed then
              update_placeholder(surface)
            end
          end,
        })
      )
    end
    update_placeholder(surface)
  end
end

function M.open(request, on_submit, on_cancel)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_get_current_buf()
  local lines = request_lines(request)
  local buf = vim.api.nvim_create_buf(false, true)
  configure_buffer(buf, request, lines)

  local layout = geometry(request.method, #lines)
  local floating = layout ~= nil
  local win
  if floating then
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = truncate_display(request.title or "Pi", math.max(1, layout.width - 2)),
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

  local previous_wrap = vim.wo[win].wrap
  local previous_cursorline = vim.wo[win].cursorline
  local surface = {
    request = request,
    buf = buf,
    win = win,
    width = floating and layout.width or math.max(1, vim.api.nvim_win_get_width(win)),
    floating = floating,
    previous_win = previous_win,
    previous_buf = previous_buf,
    selected = 1,
    previous_wrap = previous_wrap,
    previous_cursorline = previous_cursorline,
    autocmds = {},
    closed = false,
    on_submit = on_submit,
    on_cancel = on_cancel,
    secret = request.sensitive and "" or nil,
    secret_syncing = false,
  }

  function surface:render_secret()
    if self.closed or not vim.api.nvim_buf_is_valid(self.buf) then
      return
    end
    self.secret_syncing = true
    local mask = string.rep("*", vim.fn.strchars(self.secret or ""))
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { mask })
    self.secret_syncing = false
    if vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_win_set_cursor(self.win, { 1, #mask })
    end
  end

  function surface:capture_secret(value)
    self.secret = (self.secret or "") .. value
    return string.rep("*", vim.fn.strchars(value))
  end

  function surface:capture_paste(lines, _)
    if self.closed then
      return false
    end
    self.secret = (self.secret or "") .. table.concat(lines or {}, "\n")
    self:render_secret()
    return true
  end

  vim.wo[win].wrap = request.method == "confirm"
  vim.wo[win].cursorline = false
  install_lifecycle(surface)
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, on_cancel, { buffer = buf, silent = true })
  end
  if request.method == "select" or request.method == "confirm" then
    install_choice_mappings(surface)
  else
    install_text_mappings(surface)
  end

  function surface:close()
    if self.closed then
      return
    end
    self.closed = true
    if self.request.sensitive then
      remove_sensitive_paste(self)
    end
    self.secret = nil
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

  if request.method == "input" and request.sensitive then
    install_sensitive_paste(surface)
    vim.schedule(function()
      if
        not surface.closed
        and vim.api.nvim_win_is_valid(surface.win)
        and vim.api.nvim_get_current_win() == surface.win
      then
        vim.cmd("startinsert")
      end
    end)
  end

  return surface
end

return M
