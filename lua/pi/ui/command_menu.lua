-- Slash-command completion menu. CommandMenu is a method set over the
-- owning Chat instance: menu state (command_buf, command_win, matches,
-- selection) lives on the chat so callers and tests can keep addressing
-- chat.command_* fields.

local M = {}

local builtin_commands = {
  { name = "settings", description = "Open settings menu" },
  { name = "model", description = "Select model", argument_hint = "<provider/model>" },
  { name = "scoped-models", description = "Enable models for cycling", tui_only = true },
  { name = "export", description = "Export session to HTML", argument_hint = "<path.html>" },
  { name = "import", description = "Import a session from JSONL", argument_hint = "<path.jsonl>", tui_only = true },
  { name = "share", description = "Share session as a secret GitHub gist", tui_only = true },
  { name = "copy", description = "Copy last agent message" },
  { name = "name", description = "Set session display name", argument_hint = "<name>" },
  { name = "session", description = "Show session info and statistics" },
  { name = "changelog", description = "Show Pi changelog", tui_only = true },
  { name = "hotkeys", description = "Show keyboard shortcuts" },
  { name = "fork", description = "Fork from a previous user message" },
  { name = "clone", description = "Duplicate the current session branch" },
  { name = "tree", description = "Browse the session tree" },
  { name = "trust", description = "Save project trust decision", tui_only = true },
  { name = "login", description = "Configure provider authentication", argument_hint = "<provider>", tui_only = true },
  { name = "logout", description = "Remove provider authentication", tui_only = true },
  { name = "new", description = "Start a new session" },
  { name = "compact", description = "Compact session context", argument_hint = "<instructions>" },
  { name = "resume", description = "Switch to a session file", argument_hint = "<path.jsonl>" },
  { name = "reload", description = "Reload Pi resources", tui_only = true },
  { name = "quit", description = "Close the Pi panel" },
  { name = "thinking", description = "Select thinking level", argument_hint = "<level>" },
  { name = "layout", description = "Change the Pi workspace layout", argument_hint = "<layout>" },
  { name = "commands", description = "Browse available commands" },
  { name = "abort", description = "Abort the active operation" },
  { name = "clear", description = "Clear the conversation and start a fresh session" },
  {
    name = "permissions",
    description = "Select the session permission mode",
    argument_hint = "<manual|acceptEdits|auto|plan>",
  },
  { name = "mode", description = "Alias for /permissions", argument_hint = "<manual|acceptEdits|auto|plan>" },
}

function M.commands(instances)
  local commands = vim.deepcopy(builtin_commands)
  local seen = {}
  for _, command in ipairs(commands) do
    seen[command.name] = true
  end

  local root = vim.b.pi_root
  local chat = root and instances[root] or nil
  for _, command in ipairs(chat and chat.commands or {}) do
    if command.name and not seen[command.name] then
      table.insert(commands, command)
      seen[command.name] = true
    end
  end
  return commands
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
  }, CommandMenu)
  return self
end

function CommandMenu:completion_context()
  local chat = self.chat
  if not chat.input_buf or not vim.api.nvim_buf_is_valid(chat.input_buf) then
    return nil
  end
  if not chat.input_win or not vim.api.nvim_win_is_valid(chat.input_win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(chat.input_win)
  local line = vim.api.nvim_buf_get_lines(chat.input_buf, cursor[1] - 1, cursor[1], false)[1] or ""
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

function CommandMenu:visible()
  local chat = self.chat
  return chat.command_win ~= nil and vim.api.nvim_win_is_valid(chat.command_win)
end

function CommandMenu:ensure_buffer()
  local chat = self.chat
  if chat.command_buf and vim.api.nvim_buf_is_valid(chat.command_buf) then
    return chat.command_buf
  end

  chat.command_buf = vim.api.nvim_create_buf(false, true)
  self.name_buffer(chat.command_buf, "commands", chat.root)
  vim.bo[chat.command_buf].buftype = "nofile"
  vim.bo[chat.command_buf].bufhidden = "hide"
  vim.bo[chat.command_buf].swapfile = false
  vim.bo[chat.command_buf].filetype = "pi_commands"
  vim.bo[chat.command_buf].modifiable = false
  return chat.command_buf
end

function CommandMenu:close()
  local chat = self.chat
  if self:visible() then
    vim.api.nvim_win_close(chat.command_win, true)
  end
  chat.command_win = nil
  chat.command_matches = {}
  chat.command_selected = 1
  chat.command_first = 1
  chat.command_start_col = nil
  chat.command_base = nil
end

function CommandMenu:render(width, height, first)
  local chat = self.chat
  local buf = self:ensure_buffer()
  local marker_width = 2
  local content_width = math.max(1, width - marker_width)
  local longest_command = 0
  for _, match in ipairs(chat.command_matches) do
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
  local last = math.min(#chat.command_matches, first + height - 1)
  for index = first, last do
    local match = chat.command_matches[index]
    local selected = index == chat.command_selected
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
  if not self:visible() or #chat.command_matches == 0 then
    return false
  end
  if not chat.win or not vim.api.nvim_win_is_valid(chat.win) then
    self:close()
    return false
  end
  if not chat.input_win or not vim.api.nvim_win_is_valid(chat.input_win) then
    self:close()
    return false
  end

  local input_config = vim.api.nvim_win_get_config(chat.input_win)
  local input_row = math.floor(tonumber(input_config.row) or 0)
  local available_height = math.max(0, input_row)
  local height = math.min(#chat.command_matches, 12, available_height)
  if height < 1 then
    self:close()
    return false
  end

  chat.command_selected = math.max(1, math.min(chat.command_selected, #chat.command_matches))
  local maximum_first = math.max(1, #chat.command_matches - height + 1)
  local first = math.max(1, math.min(chat.command_first or 1, maximum_first))
  if chat.command_selected < first then
    first = chat.command_selected
  elseif chat.command_selected >= first + height then
    first = chat.command_selected - height + 1
  end
  chat.command_first = first

  local width = math.max(1, vim.api.nvim_win_get_width(chat.win))
  vim.api.nvim_win_set_config(chat.command_win, {
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
    chat.command_win = vim.api.nvim_open_win(buf, false, {
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
    vim.wo[chat.command_win].wrap = false
    vim.wo[chat.command_win].cursorline = false
    vim.wo[chat.command_win].number = false
    vim.wo[chat.command_win].relativenumber = false
    vim.wo[chat.command_win].signcolumn = "no"
    vim.wo[chat.command_win].foldcolumn = "0"
    vim.wo[chat.command_win].fillchars = "eob: "
    vim.wo[chat.command_win].winblend = 0
    vim.wo[chat.command_win].winbar = ""
    vim.wo[chat.command_win].winhighlight = table.concat({
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
  if vim.api.nvim_get_current_win() ~= chat.input_win then
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

  local selected_word = chat.command_matches[chat.command_selected] and chat.command_matches[chat.command_selected].word
  chat.command_matches = matches
  chat.command_selected = 1
  if selected_word then
    for index, match in ipairs(matches) do
      if match.word == selected_word then
        chat.command_selected = index
        break
      end
    end
  end
  chat.command_first = 1
  chat.command_start_col = start_col
  chat.command_base = base
  return self:open()
end

function CommandMenu:show()
  return self:update()
end

function CommandMenu:select(delta)
  local chat = self.chat
  if not self:visible() or #chat.command_matches == 0 then
    return false
  end
  local count = #chat.command_matches
  chat.command_selected = (chat.command_selected - 1 + delta) % count + 1
  self:layout()
  return true
end

function CommandMenu:accept()
  local chat = self.chat
  if not self:visible() then
    return false
  end
  local match = chat.command_matches[chat.command_selected]
  local start_col = chat.command_start_col
  if not match or not start_col then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(chat.input_win)
  vim.api.nvim_buf_set_text(
    chat.input_buf,
    cursor[1] - 1,
    start_col - 1,
    cursor[1] - 1,
    cursor[2],
    { match.word .. " " }
  )
  vim.api.nvim_win_set_cursor(chat.input_win, { cursor[1], start_col - 1 + #match.word + 1 })
  self:close()
  return true
end

M.CommandMenu = CommandMenu
M.builtin_commands = builtin_commands
return M
