local M = {}
local catalog = require("pi.commands.catalog")

function M.commands(instances)
  local root = vim.b.pi_root
  local chat = root and instances[root] or nil
  return catalog.merge(chat and chat.commands or {})
end

function M.complete(instances, findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
    local before_cursor = line:sub(1, cursor_col)
    local start_col = before_cursor:find("/[%w:_-]*$")
    if not start_col or not before_cursor:sub(1, start_col - 1):match("^%s*$") then
      return -3
    end
    return start_col - 1
  end

  local query = base:gsub("^/", ""):lower()
  local commands = M.commands(instances)
  local ranked = {}

  if query == "" then
    for _, command in ipairs(commands) do
      table.insert(ranked, { command = command, positions = {} })
    end
  else
    local names = {}
    local commands_by_name = {}
    for _, command in ipairs(commands) do
      local name = command.name:lower()
      table.insert(names, name)
      commands_by_name[name] = command
    end
    local fuzzy = vim.fn.matchfuzzypos(names, query)
    for index, name in ipairs(fuzzy[1] or {}) do
      table.insert(ranked, {
        command = commands_by_name[name],
        positions = (fuzzy[2] or {})[index] or {},
        score = (fuzzy[3] or {})[index],
      })
    end
  end

  local matches = {}
  for _, entry in ipairs(ranked) do
    local command = entry.command
    local hint = command.argument_hint and (" " .. command.argument_hint) or ""
    local kind = command.tui_only and "TUI"
      or ({ extension = "EXT", prompt = "PROMPT", skill = "SKILL" })[command.source]
      or "PI"
    table.insert(matches, {
      word = "/" .. command.name,
      abbr = "/" .. command.name .. hint,
      menu = command.description or command.source or "",
      info = command.description or "",
      kind = kind,
      dup = 0,
      match_positions = entry.positions,
      score = entry.score,
    })
  end
  return matches
end

local CommandMenu = {}
CommandMenu.__index = CommandMenu

function CommandMenu.new(chat, deps)
  local self = setmetatable({
    chat = chat,
    namespace = deps.namespace,
    name_buffer = deps.name_buffer,
    truncate_display = deps.truncate_display,
    instances = deps.instances,
    buf = nil,
    win = nil,
    matches = {},
    selected = 1,
    first = 1,
    start_col = nil,
    base = nil,
  }, CommandMenu)
  return self
end

function CommandMenu:completion_context()
  local chat = self.chat
  local input = chat.input_area
  if not input:buffer() or not vim.api.nvim_buf_is_valid(input:buffer()) then
    return nil
  end
  if not input:window() or not vim.api.nvim_win_is_valid(input:window()) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(input:window())
  local line = vim.api.nvim_buf_get_lines(input:buffer(), cursor[1] - 1, cursor[1], false)[1] or ""
  local before_cursor = line:sub(1, cursor[2])
  local leading, base = before_cursor:match("^(%s*)(/[%w:_-]*)$")
  if not base or line:sub(cursor[2] + 1):match("%S") then
    return nil
  end

  local matches = M.complete(self.instances, 0, base)
  if #matches == 0 then
    return nil
  end
  return #leading + 1, matches, base
end

function CommandMenu:complete(findstart, base)
  return M.complete(self.instances, findstart, base)
end

function CommandMenu:visible()
  local chat = self.chat
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function CommandMenu:ensure_buffer()
  local chat = self.chat
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  self.name_buffer(self.buf, "commands", chat.root)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "pi_commands"
  vim.bo[self.buf].modifiable = false
  return self.buf
end

function CommandMenu:close()
  local chat = self.chat
  if self:visible() then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
  self.matches = {}
  self.selected = 1
  self.first = 1
  self.start_col = nil
  self.base = nil
end

function CommandMenu:render(width, height, first)
  local chat = self.chat
  local buf = self:ensure_buffer()
  local marker_width = 2
  local content_width = math.max(1, width - marker_width)
  local longest_command = 0
  for _, match in ipairs(self.matches) do
    longest_command = math.max(longest_command, vim.api.nvim_strwidth(match.abbr))
  end

  local show_description = content_width >= 26
  local command_width = content_width
  local description_width = 0
  if show_description then
    command_width = math.min(longest_command, math.max(12, math.floor(content_width * 0.42)))
    description_width = content_width - command_width - 2
    if description_width < 10 then
      show_description = false
      command_width = content_width
      description_width = 0
    end
  end

  local lines = {}
  local rows = {}
  local last = math.min(#self.matches, first + height - 1)
  for index = first, last do
    local match = self.matches[index]
    local selected = index == self.selected
    local marker = selected and "› " or "  "
    local command = self.truncate_display(match.abbr, command_width)
    local command_padding = string.rep(" ", math.max(0, command_width - vim.api.nvim_strwidth(command)))
    local separator = show_description and "  " or ""
    local description = show_description and self.truncate_display(match.menu, description_width) or ""
    local line = marker .. command .. command_padding .. separator .. description
    table.insert(lines, line)
    table.insert(rows, {
      selected = selected,
      marker = marker,
      command = command,
      command_start = #marker,
      command_name_end = math.min(#command, #match.word),
      description_start = #marker + #command + #command_padding + #separator,
      description_end = #line,
      match_positions = match.match_positions or {},
    })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.namespace, 0, -1)

  for row_index, row in ipairs(rows) do
    local row_number = row_index - 1
    if row.selected then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, 0, {
        line_hl_group = "PiCommandSelected",
        priority = 80,
      })
      vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, 0, {
        end_col = #"›",
        hl_group = "PiCommandMarker",
        priority = 150,
      })
    end
    if row.command_name_end > 0 then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, row.command_start, {
        end_col = row.command_start + row.command_name_end,
        hl_group = row.selected and "PiCommandNameSelected" or "PiCommandName",
        priority = 120,
      })
    end
    if #row.command > row.command_name_end then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, row.command_start + row.command_name_end, {
        end_col = row.command_start + #row.command,
        hl_group = "PiCommandHint",
        priority = 125,
      })
    end
    if row.description_end > row.description_start then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, row.description_start, {
        end_col = row.description_end,
        hl_group = row.selected and "PiCommandDescriptionSelected" or "PiCommandDescription",
        priority = 120,
      })
    end
    for _, position in ipairs(row.match_positions) do
      local start_col = row.command_start + #"/" + position
      if start_col < row.command_start + row.command_name_end then
        vim.api.nvim_buf_set_extmark(buf, self.namespace, row_number, start_col, {
          end_col = start_col + 1,
          hl_group = "PiCommandMatch",
          priority = 170,
        })
      end
    end
  end
end

function CommandMenu:layout()
  local chat = self.chat
  local input = chat.input_area
  if not self:visible() or #self.matches == 0 then
    return false
  end
  if not chat.win or not vim.api.nvim_win_is_valid(chat.win) then
    self:close()
    return false
  end
  if not input:window() or not vim.api.nvim_win_is_valid(input:window()) then
    self:close()
    return false
  end

  local input_config = vim.api.nvim_win_get_config(input:window())
  local input_row = math.floor(tonumber(input_config.row) or 0)
  local available_height = math.max(0, input_row)
  local height = math.min(#self.matches, 12, available_height)
  if height < 1 then
    self:close()
    return false
  end

  self.selected = math.max(1, math.min(self.selected, #self.matches))
  local maximum_first = math.max(1, #self.matches - height + 1)
  local first = math.max(1, math.min(self.first or 1, maximum_first))
  if self.selected < first then
    first = self.selected
  elseif self.selected >= first + height then
    first = self.selected - height + 1
  end
  self.first = first

  local width = math.max(1, vim.api.nvim_win_get_width(chat.win))
  vim.api.nvim_win_set_config(self.win, {
    relative = "win",
    win = chat.win,
    row = input_row - height,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    zindex = 52,
  })
  self:render(width, height, first)
  return true
end

function CommandMenu:open()
  local chat = self.chat
  if not self:visible() then
    local buf = self:ensure_buffer()
    self.win = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = chat.win,
      row = 0,
      col = 0,
      width = 1,
      height = 1,
      style = "minimal",
      focusable = false,
      zindex = 52,
    })
    vim.wo[self.win].wrap = false
    vim.wo[self.win].cursorline = false
    vim.wo[self.win].number = false
    vim.wo[self.win].relativenumber = false
    vim.wo[self.win].signcolumn = "no"
    vim.wo[self.win].foldcolumn = "0"
    vim.wo[self.win].fillchars = "eob: "
    vim.wo[self.win].winblend = 0
    vim.wo[self.win].winbar = ""
    vim.wo[self.win].winhighlight = table.concat({
      "Normal:PiCommandMenu",
      "NormalNC:PiCommandMenu",
      "EndOfBuffer:PiCommandMenu",
      "WinSeparator:PiCommandMenu",
    }, ",")
  end
  return self:layout()
end

function CommandMenu:update()
  local chat = self.chat
  if vim.api.nvim_get_current_win() ~= chat.input_area:window() then
    self:close()
    return false
  end
  local start_col, matches, base = self:completion_context()
  if not start_col then
    self:close()
    return false
  end
  if #matches == 1 and matches[1].word == base then
    self:close()
    return false
  end

  local selected_word = self.matches[self.selected] and self.matches[self.selected].word
  self.matches = matches
  self.selected = 1
  if selected_word then
    for index, match in ipairs(matches) do
      if match.word == selected_word then
        self.selected = index
        break
      end
    end
  end
  self.first = 1
  self.start_col = start_col
  self.base = base
  return self:open()
end

function CommandMenu:show()
  return self:update()
end

function CommandMenu:select(delta)
  local chat = self.chat
  if not self:visible() or #self.matches == 0 then
    return false
  end
  local count = #self.matches
  self.selected = (self.selected - 1 + delta) % count + 1
  self:layout()
  return true
end

function CommandMenu:accept()
  local chat = self.chat
  local input = chat.input_area
  if not self:visible() then
    return false
  end
  local match = self.matches[self.selected]
  local start_col = self.start_col
  if not match or not start_col then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(input:window())
  vim.api.nvim_buf_set_text(
    input:buffer(),
    cursor[1] - 1,
    start_col - 1,
    cursor[1] - 1,
    cursor[2],
    { match.word .. " " }
  )
  vim.api.nvim_win_set_cursor(input:window(), { cursor[1], start_col - 1 + #match.word + 1 })
  self:close()
  return true
end

function CommandMenu:buffer()
  return self.buf
end

function CommandMenu:window()
  return self.win
end

function CommandMenu:selected_index()
  return self.selected
end

function CommandMenu:owns_buffer(bufnr)
  return bufnr ~= nil and self.buf == bufnr
end

function CommandMenu:destroy()
  self:close()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

M.CommandMenu = CommandMenu
return M
