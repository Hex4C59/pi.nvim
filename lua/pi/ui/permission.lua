local M = {}

local MIN_HEIGHT = 9
local MAX_COMPACT_HEIGHT = 15
local DEFAULT_OPTIONS = { "Block", "Allow once", "Allow for session" }

local PermissionPanel = {}
PermissionPanel.__index = PermissionPanel

local function options_for(request)
  if type(request.options) == "table" and #request.options > 0 then
    return request.options
  end
  return DEFAULT_OPTIONS
end

local function choice_kind(label)
  local normalized = vim.trim(string.lower(label or ""))
  if normalized == "block" or normalized == "deny" or normalized == "no" then
    return "block"
  elseif normalized:find("session", 1, true) then
    return "session"
  end
  return "allow"
end

local function highlight_shell_line(row, line, marks)
  local prompt_start = line:find("$ ", 1, true)
  local source_start
  if prompt_start then
    source_start = prompt_start + 2
  else
    local leading = line:match("^%s*") or ""
    source_start = #leading + 1
  end
  if source_start > #line then
    return
  end

  local source = line:sub(source_start)
  local base = source_start - 1
  local function mark(start_col, end_col, group)
    if end_col < start_col then
      return
    end
    table.insert(marks, {
      row = row,
      start_col = base + start_col - 1,
      end_col = base + end_col,
      highlight = group,
      priority = 175,
    })
  end

  local function operator_length(index)
    local two = source:sub(index, index + 1)
    if two == "&&" or two == "||" or two == ">>" or two == "<<" then
      return 2
    end
    if source:sub(index, index):match("[|;&><()]") then
      return 1
    end
    return nil
  end

  local index = 1
  local command_expected = true
  while index <= #source do
    local character = source:sub(index, index)
    if character:match("%s") then
      index = index + 1
    elseif character == "'" or character == "\"" then
      local quote = character
      local finish = index + 1
      while finish <= #source do
        if source:sub(finish, finish) == "\\" and quote == "\"" then
          finish = finish + 2
        elseif source:sub(finish, finish) == quote then
          break
        else
          finish = finish + 1
        end
      end
      mark(index, math.min(finish, #source), "PiPermissionShellString")
      index = math.min(finish + 1, #source + 1)
      command_expected = false
    elseif character == "$" then
      local finish = index + 1
      if source:sub(finish, finish) == "{" then
        finish = source:find("}", finish + 1, true) or #source
      else
        while finish <= #source and source:sub(finish, finish):match("[%w_]") do
          finish = finish + 1
        end
        finish = math.max(index, finish - 1)
      end
      mark(index, finish, "PiPermissionShellVariable")
      index = finish + 1
    else
      local operator = operator_length(index)
      if operator then
        mark(index, index + operator - 1, "PiPermissionShellOperator")
        command_expected = true
        index = index + operator
      elseif character == "-" and source:sub(index + 1, index + 1):match("[%w-]") then
        local finish = index + 1
        while finish <= #source do
          local value = source:sub(finish, finish)
          if
            value:match("%s")
            or value == "|"
            or value == ";"
            or value == "&"
            or value == ">"
            or value == "<"
            or value == "("
            or value == ")"
            or value == "'"
            or value == "\""
          then
            break
          end
          finish = finish + 1
        end
        mark(index, finish - 1, "PiPermissionShellOption")
        index = finish
        command_expected = false
      else
        local finish = index
        while finish <= #source do
          local value = source:sub(finish, finish)
          if value:match("%s") or value == "'" or value == "\"" or value == "$" or operator_length(finish) then
            break
          end
          finish = finish + 1
        end
        if command_expected then
          mark(index, finish - 1, "PiPermissionShellCommand")
        end
        index = finish
        command_expected = false
      end
    end
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

local function wrap_line(text, width, first_prefix, continuation_prefix)
  width = math.max(1, width)
  first_prefix = first_prefix or ""
  continuation_prefix = continuation_prefix or first_prefix
  local lines = {}
  local current = first_prefix
  local current_prefix = first_prefix

  if text == "" then
    return { current }
  end

  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    if vim.api.nvim_strwidth(current .. character) > width and current ~= current_prefix then
      table.insert(lines, current)
      current_prefix = continuation_prefix
      current = continuation_prefix .. character
    else
      current = current .. character
    end
  end
  table.insert(lines, current)
  return lines
end

local function presentation(request)
  local title = request.title or "Confirm action"
  local details = request.message or ""
  if title == "Allow model Bash command?" or title == "Bash command" then
    return "Bash command", "$ ", "  ", true
  elseif title == "Allow model file write?" or title == "File write" then
    return "File write", "", "", false
  elseif title == "Allow model file edit?" or title == "File edit" then
    return "File edit", "", "", false
  elseif title == "Allow model read outside workspace?" or title == "Read outside workspace" then
    return "Read outside workspace", "", "", false
  end
  return title:gsub("%?$", ""), "", "", false
end

function PermissionPanel.new(deps)
  return setmetatable({
    root = deps.root,
    main_window = deps.main_window,
    transcript_buffer = deps.transcript_buffer,
    input_window = deps.input_window,
    actions = deps.actions,
    queue = {},
    current = nil,
    selected = 1,
    expanded = false,
    body_offset = 1,
    body_lines = {},
    body_budget = 1,
    available_height = MAX_COMPACT_HEIGHT,
    return_win = nil,
    return_mode = nil,
    key_namespace = vim.api.nvim_create_namespace("pi.nvim.permission.keys." .. vim.fn.sha256(deps.root):sub(1, 12)),
  }, PermissionPanel)
end

function PermissionPanel:active()
  return self.current ~= nil
end

function PermissionPanel:_select(delta)
  if not self.current then
    return
  end
  local option_count = #options_for(self.current.request)
  self.selected = (self.selected - 1 + delta) % math.max(1, option_count) + 1
  self.actions.render()
end

function PermissionPanel:_resolve_selected()
  if not self.current then
    return
  end
  local options = options_for(self.current.request)
  self:_resolve(options[self.selected])
end

function PermissionPanel:_block()
  if self.current then
    self:_resolve(options_for(self.current.request)[1])
  end
end

function PermissionPanel:_toggle_expanded()
  self.expanded = not self.expanded
  self.body_offset = 1
  self.actions.render()
end

function PermissionPanel:_handle_key(raw_key)
  local key = vim.fn.keytrans(raw_key)
  if key == "j" or key == "<Down>" then
    self:_select(1)
  elseif key == "k" or key == "<Up>" then
    self:_select(-1)
  elseif key == "<CR>" then
    self:_resolve_selected()
  elseif key == "<Esc>" then
    self:_block()
  elseif key == "<C-Q>" then
    self:exit_to_normal()
  elseif key == "e" then
    self:_toggle_expanded()
  elseif key == "<C-D>" or key == "<PageDown>" then
    self:_scroll(math.max(1, math.floor(self.body_budget / 2)))
  elseif key == "<C-U>" or key == "<PageUp>" then
    self:_scroll(-math.max(1, math.floor(self.body_budget / 2)))
  else
    return false
  end
  return true
end

function PermissionPanel:_install_key_capture()
  vim.on_key(function(_, typed)
    if not self:active() or typed == "" then
      return
    end
    self:_handle_key(typed)
    -- Neovim 0.11+ consumes this key; 0.10 still observes the original typed
    -- key so permission navigation remains authoritative over the selection.
    return ""
  end, self.key_namespace)
end

function PermissionPanel:_remove_key_capture()
  vim.on_key(nil, self.key_namespace)
end

function PermissionPanel:_deactivate()
  self:_remove_key_capture()
end

function PermissionPanel:_focus()
  local main_win = self.main_window()
  local transcript_buf = self.transcript_buffer()
  if not main_win or not vim.api.nvim_win_is_valid(main_win) or not transcript_buf then
    return
  end
  vim.api.nvim_set_current_win(main_win)
  vim.api.nvim_win_set_cursor(main_win, { vim.api.nvim_buf_line_count(transcript_buf), 0 })
  self:_install_key_capture()
  vim.cmd("stopinsert")
end

function PermissionPanel:focus()
  if self:active() then
    self:_focus()
  end
end

function PermissionPanel:show(request, callback)
  table.insert(self.queue, { request = request, callback = callback })
  if self.current then
    self.actions.render()
    return
  end

  self.return_win = vim.api.nvim_get_current_win()
  self.return_mode = vim.api.nvim_get_mode().mode
  self:_advance()
end

function PermissionPanel:_advance()
  self.current = table.remove(self.queue, 1)
  self.selected = 1
  self.expanded = false
  self.body_offset = 1
  if not self.current then
    self:_deactivate()
    self.actions.layout()
    self.actions.render()
    self:_restore_focus()
    return
  end

  self.actions.close_command_menu()
  self.actions.layout()
  self.actions.render()
  self:_focus()
end

function PermissionPanel:_restore_focus()
  local win = self.return_win
  local mode = self.return_mode
  self.return_win = nil
  self.return_mode = nil
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  if win == self.input_window() and mode and mode:sub(1, 1) == "i" then
    vim.cmd("startinsert")
  end
end

function PermissionPanel:exit_to_normal()
  if not self:active() then
    return
  end
  local main_win = self.main_window()
  local target = main_win and vim.api.nvim_win_is_valid(main_win) and main_win or self.return_win
  self:cancel_all(true, target)
  self.actions.layout()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
    vim.cmd("stopinsert")
  end
end

function PermissionPanel:_resolve(allowed)
  if not self.current then
    return
  end
  local callback = self.current.callback
  self.current = nil
  if callback then
    callback(allowed)
  end
  self:_advance()
end

function PermissionPanel:cancel_all(force_normal, target_win)
  if not self.current and #self.queue == 0 then
    self:_deactivate()
    return
  end
  local pending = {}
  if self.current then
    table.insert(pending, self.current)
  end
  vim.list_extend(pending, self.queue)
  self.current = nil
  self.queue = {}
  self:_deactivate()
  for _, item in ipairs(pending) do
    if item.callback then
      item.callback(false)
    end
  end
  self.actions.layout()
  self.actions.render()
  local return_win = target_win or self.return_win
  if force_normal and return_win and vim.api.nvim_win_is_valid(return_win) then
    vim.api.nvim_set_current_win(return_win)
    vim.cmd("stopinsert")
  end
  self.return_win = nil
  self.return_mode = nil
end

function PermissionPanel:destroy()
  self:cancel_all()
  self.body_lines = {}
  self.body_marks = {}
end

function PermissionPanel:_scroll(delta)
  local maximum = math.max(1, #self.body_lines - self.body_budget + 1)
  local next_offset = math.max(1, math.min(maximum, self.body_offset + delta))
  if next_offset ~= self.body_offset then
    self.body_offset = next_offset
    self.actions.render()
  end
end

function PermissionPanel:_body(width)
  local request = self.current.request
  local _, first_prefix, continuation_prefix, shell = presentation(request)
  local content_width = math.max(8, width - 6)
  local body = {}
  local message_lines = vim.split(request.message or "", "\n", { plain = true })
  for index, line in ipairs(message_lines) do
    local prefix = index == 1 and first_prefix or continuation_prefix
    vim.list_extend(body, wrap_line(line, content_width, prefix, continuation_prefix))
  end
  if #body == 0 then
    body = { "No additional details" }
  end
  if shell then
    local cwd = vim.fn.fnamemodify(self.root, ":~")
    table.insert(body, 1, "cwd  " .. cwd)
  end
  return body, shell
end

function PermissionPanel:_compose(width, height)
  local request = self.current.request
  local subject = presentation(request)
  local lines = {}
  local marks = {}
  local content_width = math.max(1, width)

  local function add(text, kind, extra)
    text = truncate_display(text or "", content_width)
    local row = #lines
    table.insert(lines, text)
    table.insert(marks, {
      row = row,
      kind = kind,
      start_col = extra and extra.start_col or 0,
      end_col = #text,
      marker_start = extra and extra.marker_start,
      marker_end = extra and extra.marker_end,
      detail_start = extra and extra.detail_start,
      detail_end = extra and extra.detail_end,
      detail_highlight = extra and extra.detail_highlight,
      marker_highlight = extra and extra.marker_highlight,
    })
    return row
  end

  local pending = #self.queue
  local heading = subject
  if pending > 0 then
    heading = heading .. (" · %d pending"):format(pending)
  end
  add(string.rep("─", math.max(1, width)), "rule")
  add(" " .. heading, "title", { start_col = 1 })
  add("", nil)

  local body, shell = self:_body(width)
  self.body_lines = body
  local fixed_height = 9
  local body_budget = math.max(1, height - fixed_height)
  self.body_budget = body_budget
  local maximum_offset = math.max(1, #self.body_lines - body_budget + 1)
  self.body_offset = math.min(self.body_offset, maximum_offset)
  local body_last = math.min(#self.body_lines, self.body_offset + body_budget - 1)
  for index = self.body_offset, body_last do
    local line = self.body_lines[index]
    local cwd = line:match("^cwd%s%s(.+)$")
    local command_line = shell and not cwd
    local command_prompt = command_line and line:sub(1, 2) == "$ "
    add("   " .. line, cwd and "meta" or command_line and "command" or "body", {
      start_col = 3,
      detail_start = cwd and (3 + #"cwd  ") or command_prompt and 3 or nil,
      detail_end = cwd and (3 + #line) or command_prompt and (3 + #"$") or nil,
      detail_highlight = cwd and "PiPermissionPath" or command_prompt and "PiPermissionCommandPrompt" or nil,
    })
  end
  if body_last < #self.body_lines and body_budget > 2 then
    local overflow = truncate_display(("   ... %d more lines"):format(#self.body_lines - body_last), content_width)
    lines[#lines] = overflow
    marks[#marks].kind = "meta"
    marks[#marks].start_col = 3
    marks[#marks].end_col = #overflow
  end
  add("", nil)

  add(" Do you want to proceed?", "question", { start_col = 1 })
  local options = options_for(request)
  for index, label in ipairs(options) do
    local selected = self.selected == index
    local marker = selected and "❯" or " "
    local line = (" %s %s"):format(marker, label)
    local kind = choice_kind(label)
    local choice_highlight = kind == "block" and "PiPermissionBlock"
      or kind == "session" and "PiPermissionSession"
      or "PiPermissionAllow"
    local selected_highlight = kind == "block" and "PiPermissionBlockSelected"
      or kind == "session" and "PiPermissionSessionSelected"
      or "PiPermissionAllowSelected"
    add(line, "choice", {
      start_col = 1,
      marker_start = selected and 1 or nil,
      marker_end = selected and (1 + #marker) or nil,
      detail_start = 1 + #marker + 1,
      detail_end = #line,
      detail_highlight = selected and selected_highlight or choice_highlight,
      marker_highlight = selected_highlight,
    })
  end

  local can_scroll = #self.body_lines > self.body_budget
  local hints
  if content_width < 58 then
    local navigation = "j/k or arrows · enter · esc"
    if not self.expanded and #self.body_lines > math.max(1, MAX_COMPACT_HEIGHT - fixed_height) then
      hints = "ctrl-q cancel · e expand · " .. navigation
    elseif self.expanded then
      hints = can_scroll and "ctrl-q cancel · ctrl-u/d scroll · e minimize · " .. navigation
        or "ctrl-q cancel · e minimize · " .. navigation
    else
      hints = "ctrl-q cancel · " .. navigation
    end
  else
    local navigation = "j/k or arrows select · enter confirm · esc block"
    if can_scroll then
      navigation = "ctrl-u/d scroll · " .. navigation
    end
    if not self.expanded and #self.body_lines > math.max(1, MAX_COMPACT_HEIGHT - fixed_height) then
      hints = "ctrl-q cancel · e expand · " .. navigation
    elseif self.expanded then
      hints = "ctrl-q cancel · e minimize · " .. navigation
    else
      hints = "ctrl-q cancel · " .. navigation
    end
  end
  add(" " .. hints, "hint", { start_col = 1 })
  return lines, marks
end

function PermissionPanel:set_available_height(height)
  self.available_height = math.max(1, height or MAX_COMPACT_HEIGHT)
end

function PermissionPanel:transcript_content(width)
  if not self.current then
    return {}, {}
  end
  local available = self.available_height or MAX_COMPACT_HEIGHT
  local desired = self.expanded and available or math.min(MAX_COMPACT_HEIGHT, available)
  local body_lines = self:_body(width)
  local natural = math.max(MIN_HEIGHT, 9 + #body_lines)
  local height = math.max(1, math.min(desired, natural))
  local lines, specs = self:_compose(width, height)
  local marks = {}
  local groups = {
    rule = "PiPermissionRule",
    title = "PiPermissionTitle",
    body = "PiPermissionBody",
    command = "PiPermissionCommand",
    meta = "PiPermissionHint",
    question = "PiPermissionQuestion",
    choice = "PiPermissionChoice",
    hint = "PiPermissionHint",
  }
  local function add_mark(row, start_col, end_col, highlight, priority)
    if highlight and end_col and start_col and end_col > start_col then
      table.insert(marks, {
        row = row,
        start_col = start_col,
        end_col = end_col,
        highlight = highlight,
        priority = priority,
      })
    end
  end
  for _, spec in ipairs(specs) do
    add_mark(spec.row, spec.start_col, spec.end_col, groups[spec.kind], 130)
    add_mark(spec.row, spec.detail_start, spec.detail_end, spec.detail_highlight, 155)
    add_mark(spec.row, spec.marker_start, spec.marker_end, spec.marker_highlight or "PiPermissionMarker", 160)
    if spec.kind == "command" then
      highlight_shell_line(spec.row, lines[spec.row + 1] or "", marks)
    end
  end
  return lines, marks
end

M.PermissionPanel = PermissionPanel
return M
