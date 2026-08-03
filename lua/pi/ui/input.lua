-- Prompt input and status-bar area. InputArea is a method set over the
-- owning Chat instance: buffer/window handles and state stay on the chat
-- (chat.input_buf, chat.input_win, chat.status_buf, chat.status_win) so
-- callers and tests keep addressing chat.* directly.

local M = {}

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

local InputArea = {}
InputArea.__index = InputArea

function InputArea.new(chat, deps)
  local self = setmetatable({
    chat = chat,
    namespace = deps.namespace,
    ui_group = deps.ui_group,
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

  local top = line_chunks(1, width, "▔")
  local label = active and (" " .. chat:_activity_text() .. " ") or chat.activity == "error" and " Error " or nil
  if not label then
    return top, line_chunks(1, width, "▁"), base_highlight, corner_highlight
  end

  label = truncate_display(label, width)
  local label_width = vim.api.nvim_strwidth(label)
  local left_width = math.floor((width - label_width) / 2)
  local bottom = line_chunks(1, left_width, "▁")
  append_chunk(bottom, label, chat.activity == "error" and "PiInputBorderError" or "PiInputActivity")
  for index = left_width + label_width + 1, width do
    append_chunk(bottom, "▁", cell_highlights[index])
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
    col = 1,
    width = width,
    height = height,
    style = "minimal",
    border = {
      { "╱", corner_highlight },
      { "▔", border_highlight },
      { "╲", corner_highlight },
      { "▕", border_highlight },
      { "╱", corner_highlight },
      { "▁", border_highlight },
      { "╲", corner_highlight },
      { "▏", border_highlight },
    },
    title = top,
    title_pos = "center",
    footer = bottom,
    footer_pos = "center",
    zindex = 50,
  }
end

function InputArea:update_chrome()
  local chat = self.chat
  if not chat.input_win or not vim.api.nvim_win_is_valid(chat.input_win) then
    return
  end
  vim.wo[chat.input_win].winbar = " "
  vim.wo[chat.input_win].winhighlight = table.concat({
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
  local line, right_start = compose_line(chat.model .. " · " .. chat.thinking, right, content_width)
  return { status_padding .. line }, { #status_padding + right_start }
end

function InputArea:render_status()
  local chat = self.chat
  if not chat.status_buf or not vim.api.nvim_buf_is_valid(chat.status_buf) then
    return
  end
  local width = chat.status_win
      and vim.api.nvim_win_is_valid(chat.status_win)
      and vim.api.nvim_win_get_width(chat.status_win)
    or 80
  local lines, right_starts = self:status_text(width)
  vim.bo[chat.status_buf].modifiable = true
  vim.api.nvim_buf_set_lines(chat.status_buf, 0, -1, false, lines)
  vim.bo[chat.status_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(chat.status_buf, self.namespace, 0, -1)

  local function highlight(row, start_col, end_col, group, priority)
    if end_col <= start_col then
      return
    end
    vim.api.nvim_buf_set_extmark(chat.status_buf, self.namespace, row, start_col, {
      end_col = end_col,
      hl_group = group,
      priority = priority or 100,
    })
  end

  highlight(0, #status_padding, math.min(right_starts[1], #lines[1]), "PiStatusModel")
  local thinking_start = lines[1]:find(chat.thinking, #status_padding + 1, true)
  if thinking_start then
    highlight(0, thinking_start - 1, thinking_start - 1 + #chat.thinking, "PiStatusThinking", 130)
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
  local chat = self.chat
  local config = require("pi.config")
  local maximum = math.max(3, config.get().chat.max_input_height or 8)
  return math.max(3, math.min(vim.api.nvim_buf_line_count(chat.input_buf) + 2, maximum))
end

function InputArea:resize()
  self.chat:_layout()
end

function InputArea:set_input(text)
  local chat = self.chat
  chat:_close_command_menu()
  local buf = self:ensure_input_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
  self:resize()
  if chat.input_win and vim.api.nvim_win_is_valid(chat.input_win) then
    self:focus()
    local last = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    vim.api.nvim_win_set_cursor(chat.input_win, { last, #line })
  end
end

function InputArea:focus()
  local chat = self.chat
  if not chat.input_win or not vim.api.nvim_win_is_valid(chat.input_win) then
    return
  end
  vim.api.nvim_set_current_win(chat.input_win)
  vim.cmd("startinsert")
end

function InputArea:ensure_input_buffer()
  local chat = self.chat
  if chat.input_buf and vim.api.nvim_buf_is_valid(chat.input_buf) then
    isolate_input_completion(chat.input_buf)
    return chat.input_buf
  end

  chat.input_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(chat.input_buf, "prompt", chat.root)
  vim.bo[chat.input_buf].buftype = "nofile"
  vim.bo[chat.input_buf].bufhidden = "hide"
  vim.bo[chat.input_buf].swapfile = false
  isolate_input_completion(chat.input_buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.ui_group,
    buffer = chat.input_buf,
    callback = function(event)
      self:resize()
      if event.event == "TextChangedI" then
        vim.schedule(function()
          if chat.input_buf and vim.api.nvim_buf_is_valid(chat.input_buf) then
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
    buffer = chat.input_buf,
    callback = function()
      chat:_close_command_menu()
    end,
  })

  local function submit(behavior)
    local lines = vim.api.nvim_buf_get_lines(chat.input_buf, 0, -1, false)
    local prompt = vim.trim(table.concat(lines, "\n"))
    if prompt == "" then
      return
    end
    chat:_close_command_menu()
    vim.api.nvim_buf_set_lines(chat.input_buf, 0, -1, false, { "" })
    self:resize()
    vim.api.nvim_win_set_cursor(chat.input_win, { 1, 0 })
    require("pi").submit(prompt, chat.root, behavior)
  end

  local function feed(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
  end

  vim.keymap.set("n", "<CR>", function()
    submit(nil)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    if chat:_accept_command_completion() then
      return
    end
    submit(nil)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<M-CR>", function()
    submit("followUp")
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = chat.input_buf, silent = true })
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
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<Down>", function()
    if not chat:_select_command(1) then
      feed("<Down>")
    end
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<Up>", function()
    if not chat:_select_command(-1) then
      feed("<Up>")
    end
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<C-n>", function()
    if not chat:_select_command(1) then
      feed("<C-n>")
    end
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("n", "q", function()
    chat:close()
  end, { buffer = chat.input_buf, silent = true })
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
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    require("pi").abort(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-l>", function()
    require("pi").select_model(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    require("pi").cycle_model(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<C-p>", function()
    if chat:_select_command(-1) then
      return
    end
    require("pi").cycle_model(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pi").cycle_thinking_level(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set("i", "<S-Tab>", function()
    if chat:_select_command(-1) then
      return
    end
    require("pi").cycle_thinking_level(chat.root)
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-o>", function()
    chat:toggle_tools()
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    chat:toggle_thinking()
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-x>", function()
    chat:copy_last_assistant()
  end, { buffer = chat.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<LeftMouse>", function()
    dispatch_left_mouse(chat)
  end, { buffer = chat.input_buf, silent = true })
  return chat.input_buf
end

function InputArea:ensure_status_buffer()
  local chat = self.chat
  if chat.status_buf and vim.api.nvim_buf_is_valid(chat.status_buf) then
    return chat.status_buf
  end
  chat.status_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(chat.status_buf, "status", chat.root)
  vim.bo[chat.status_buf].buftype = "nofile"
  vim.bo[chat.status_buf].bufhidden = "hide"
  vim.bo[chat.status_buf].swapfile = false
  vim.bo[chat.status_buf].filetype = "pi_status"
  vim.bo[chat.status_buf].modifiable = false
  return chat.status_buf
end

M.InputArea = InputArea
M.name_buffer = name_buffer
M.dispatch_left_mouse = dispatch_left_mouse
M.truncate_display = truncate_display
return M
