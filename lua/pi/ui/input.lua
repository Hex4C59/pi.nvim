-- Prompt input and status-bar area. InputArea owns its buffers and windows;
-- Chat only coordinates their placement with the transcript and widgets.

local M = {}
local attachment_namespace = vim.api.nvim_create_namespace("pi.nvim.input.attachments")

local function name_buffer(buf, kind, root)
  local titles = { chat = "Pi Chat", commands = "Pi Commands", prompt = "Pi", status = "Pi Status" }
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

local function dispatch_left_mouse(chat)
  if not chat:_handle_left_mouse() then
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

local function permission_highlight(chat)
  return permission_highlights[chat:permission_mode()] or "PiStatusPermission"
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

function InputArea.new(chat, deps)
  local self = setmetatable({
    chat = chat,
    namespace = deps.namespace,
    ui_group = deps.ui_group,
    input_line_count = nil,
    input_buf = nil,
    input_win = nil,
    status_buf = nil,
    status_win = nil,
  }, InputArea)
  return self
end

function InputArea:frame(width)
  local chat = self.chat
  width = math.max(1, math.floor(width or 1))
  local active = chat:_is_active()
  local base_highlight = chat.activity == "error" and "PiInputBorderError"
    or active and "PiInputBorderMuted"
    or "PiInputBorder"
  local corner_highlight = chat.activity == "error" and "PiInputCornerError"
    or active and "PiInputCornerMuted"
    or "PiInputCorner"
  local cell_highlights = {}

  if active and width > 1 then
    local travel = math.max(1, math.floor((width - 1) / 2))
    local period = travel * 2
    local step = (chat.animation_frame or 0) * 2 % period
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
  local label = active and (" " .. chat:_activity_text() .. " ") or chat.activity == "error" and " Error " or nil
  if not label then
    return top, line_chunks(1, width, "─"), base_highlight, corner_highlight
  end

  label = truncate_display(label, width)
  local label_width = vim.api.nvim_strwidth(label)
  local left_width = math.floor((width - label_width) / 2)
  local bottom = line_chunks(1, left_width, "─")
  append_chunk(bottom, label, chat.activity == "error" and "PiInputBorderError" or "PiInputActivity")
  for index = left_width + label_width + 1, width do
    append_chunk(bottom, "─", cell_highlights[index])
  end
  return top, bottom, base_highlight, corner_highlight
end

function InputArea:window_config(row, width, height)
  local chat = self.chat
  local top, bottom, border_highlight, corner_highlight = self:frame(width)
  return {
    relative = "win",
    win = chat.win,
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
  local chat = self.chat
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
  chat:_layout()
end

function InputArea:status_text(width)
  local chat = self.chat
  local context_usage = chat.stats.contextUsage or {}
  local steering = #(chat.queue.steering or {})
  local follow_up = #(chat.queue.followUp or {})
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
  local permission = chat:permission_mode_label()
  local compact = content_width < 60
  local left = compact and permission or (chat.model .. " · " .. chat.thinking)
  if not compact then
    right = permission .. " · " .. right
  end
  local line, right_start = compose_line(left, right, content_width)
  return { status_padding .. line }, { #status_padding + right_start }
end

function InputArea:render_status()
  local chat = self.chat
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
  local permission_label = chat:permission_mode_label()
  local permission_group = permission_highlight(chat)
  if compact then
    local permission_start = lines[1]:find(permission_label, #status_padding + 1, true)
    if permission_start then
      highlight(0, permission_start - 1, permission_start - 1 + #permission_label, permission_group, 150)
    end
  else
    highlight(0, #status_padding, math.min(right_starts[1], #lines[1]), "PiStatusModel")
    local thinking_start = lines[1]:find(chat.thinking, #status_padding + 1, true)
    if thinking_start then
      highlight(0, thinking_start - 1, thinking_start - 1 + #chat.thinking, "PiStatusThinking", 130)
    end
    local permission_start = lines[1]:find(permission_label, right_starts[1] + 1, true)
    if permission_start then
      highlight(0, permission_start - 1, permission_start - 1 + #permission_label, permission_group, 150)
    end
  end

  local right_highlight = "PiStatusContext"
  if #(chat.queue.steering or {}) > 0 or #(chat.queue.followUp or {}) > 0 then
    right_highlight = "PiStatusWorking"
  else
    local percent = tonumber((chat.stats.contextUsage or {}).percent)
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
  return math.max(3, math.min(vim.api.nvim_buf_line_count(self.input_buf) + 2, maximum))
end

function InputArea:resize()
  local chat = self.chat
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(self.input_buf)
  if self.input_line_count == line_count then
    return
  end
  self.input_line_count = line_count
  chat:_layout()
end

function InputArea:set_input(text)
  local chat = self.chat
  chat:_close_command_menu()
  local buf = self:ensure_input_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
  self:resize()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    self:focus()
    local last = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    vim.api.nvim_win_set_cursor(self.input_win, { last, #line })
  end
end

function InputArea:render_attachments()
  local chat = self.chat
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.input_buf, attachment_namespace, 0, -1)
  local count = #(chat.pending_images or {})
  if count == 0 then
    return
  end
  local last = vim.api.nvim_buf_line_count(self.input_buf)
  local line = vim.api.nvim_buf_get_lines(self.input_buf, last - 1, last, false)[1] or ""
  vim.api.nvim_buf_set_extmark(self.input_buf, attachment_namespace, last - 1, #line, {
    virt_text = { { ("  [%d image%s attached]"):format(count, count == 1 and "" or "s"), "PiInputAttachment" } },
    virt_text_pos = "eol",
    priority = 120,
  })
end

function InputArea:focus()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  vim.api.nvim_set_current_win(self.input_win)
  vim.cmd("startinsert")
end

function InputArea:ensure_input_buffer()
  local chat = self.chat
  if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
    isolate_input_completion(self.input_buf)
    return self.input_buf
  end

  self.input_buf = vim.api.nvim_create_buf(false, true)
  local input_buf = self.input_buf
  name_buffer(input_buf, "prompt", chat.root)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].bufhidden = "hide"
  vim.bo[input_buf].swapfile = false
  isolate_input_completion(input_buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.ui_group,
    buffer = input_buf,
    callback = function(event)
      self:resize()
      if event.event == "TextChangedI" then
        vim.schedule(function()
          if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
            chat:_update_command_menu()
          end
        end)
      else
        chat:_close_command_menu()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave" }, {
    group = self.ui_group,
    buffer = input_buf,
    callback = function()
      chat:_close_command_menu()
    end,
  })

  local function submit(behavior)
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local prompt = vim.trim(table.concat(lines, "\n"))
    if prompt == "" and #(chat.pending_images or {}) == 0 then
      return
    end
    local images = chat:take_image_attachments()
    chat:_close_command_menu()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    self:resize()
    vim.api.nvim_win_set_cursor(self.input_win, { 1, 0 })
    require("pi").submit(prompt, chat.root, behavior, images)
  end

  local function feed(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
  end

  local function paste_clipboard()
    local image, err = require("pi.clipboard").read_image()
    if image then
      local added, attachment_err = chat:add_image_attachment(image)
      if not added and attachment_err then
        vim.notify(attachment_err, vim.log.levels.WARN, { title = "Pi clipboard" })
      end
      return
    end
    if err then
      vim.notify(err, vim.log.levels.WARN, { title = "Pi clipboard" })
    end
    local text = require("pi.clipboard").read_text()
    if text then
      vim.paste(text, -1)
    else
      feed("<C-v>")
    end
  end

  vim.keymap.set("n", "<CR>", function()
    submit(nil)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    if chat:_accept_command_completion() then
      return
    end
    submit(nil)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<M-CR>", function()
    submit("followUp")
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<Tab>", function()
    if chat:_command_menu_visible() then
      chat:_select_command(1)
      return
    end
    local line = vim.api.nvim_get_current_line()
    if line:match("^%s*/") and chat:_update_command_menu() then
      return
    end
    feed("<Tab>")
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<C-v>", paste_clipboard, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<C-S-v>", paste_clipboard, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<Down>", function()
    if not chat:_select_command(1) then
      feed("<Down>")
    end
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<Up>", function()
    if not chat:_select_command(-1) then
      feed("<Up>")
    end
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<C-n>", function()
    if not chat:_select_command(1) then
      feed("<C-n>")
    end
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("n", "q", function()
    chat:close()
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<Esc>", function()
    if chat:_command_menu_visible() then
      chat:_close_command_menu()
      return
    end
    if chat.activity ~= "idle" and chat.activity ~= "starting" then
      require("pi").abort(chat.root)
      return
    end
    feed("<Esc>")
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    require("pi").abort(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-l>", function()
    require("pi").select_model(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    require("pi").cycle_model(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<C-p>", function()
    if chat:_select_command(-1) then
      return
    end
    require("pi").cycle_model(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<M-p>", function()
    require("pi").cycle_permission_mode(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pi").cycle_thinking_level(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set("i", "<S-Tab>", function()
    if chat:_select_command(-1) then
      return
    end
    require("pi").cycle_thinking_level(chat.root)
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-o>", function()
    chat:toggle_tools()
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    chat:toggle_thinking()
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-x>", function()
    chat:copy_last_assistant()
  end, { buffer = input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<LeftMouse>", function()
    dispatch_left_mouse(chat)
  end, { buffer = input_buf, silent = true })
  return input_buf
end

function InputArea:ensure_status_buffer()
  local chat = self.chat
  if self.status_buf and vim.api.nvim_buf_is_valid(self.status_buf) then
    return self.status_buf
  end
  self.status_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.status_buf, "status", chat.root)
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
  for _, win in pairs({ self.status_win, self.input_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  self.status_win = nil
  self.input_win = nil
end

function InputArea:owns_buffer(bufnr)
  return bufnr ~= nil and (self.input_buf == bufnr or self.status_buf == bufnr)
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
return M
