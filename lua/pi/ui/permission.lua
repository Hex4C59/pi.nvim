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

local function highlight_shell_line(buf, namespace, row, line)
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
    vim.api.nvim_buf_set_extmark(buf, namespace, row, base + start_col - 1, {
      end_col = base + end_col,
      hl_group = group,
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

local function isolate_buffer(buf)
  local options = vim.bo[buf]
  options.buftype = "nofile"
  options.bufhidden = "hide"
  options.swapfile = false
  options.filetype = "pi_permission"
  options.syntax = ""
  options.modifiable = false
  options.completefunc = ""
  options.omnifunc = ""
  options.tagfunc = ""
  options.formatexpr = ""
  options.indentexpr = ""
  options.formatoptions = ""
  options.textwidth = 0
  vim.b[buf].pi_permission_owned = true
  vim.b[buf].did_ftplugin = 1
  vim.b[buf].completion = false
  vim.b[buf].cmp_enabled = false
  vim.b[buf].coc_enabled = false
  vim.b[buf].illuminate_disable = true
end

local function isolate_window(win)
  local options = vim.wo[win]
  options.wrap = false
  options.number = false
  options.relativenumber = false
  options.signcolumn = "no"
  options.foldcolumn = "0"
  options.cursorline = false
  options.cursorcolumn = false
  options.colorcolumn = ""
  options.spell = false
  options.diff = false
  options.foldmethod = "manual"
  options.foldenable = false
  options.conceallevel = 0
  options.concealcursor = ""
  options.virtualedit = ""
  options.statuscolumn = ""
  options.winbar = ""
  pcall(function()
    options.winfixbuf = true
  end)
  options.winhighlight = table.concat({
    "Normal:PiPermissionNormal",
    "NormalNC:PiPermissionNormal",
    "EndOfBuffer:PiPermissionNormal",
    "Cursor:PiPermissionCursor",
    "lCursor:PiPermissionCursor",
    "CursorLine:PiPermissionNormal",
    "CursorColumn:PiPermissionNormal",
    "ColorColumn:PiPermissionNormal",
    "SignColumn:PiPermissionNormal",
    "FoldColumn:PiPermissionNormal",
    "LineNr:PiPermissionNormal",
    "CursorLineNr:PiPermissionNormal",
    "Visual:PiPermissionVisual",
    "Search:PiPermissionNormal",
    "IncSearch:PiPermissionNormal",
    "CurSearch:PiPermissionNormal",
    "MatchParen:PiPermissionNormal",
    "Pmenu:PiPermissionNormal",
    "PmenuSel:PiPermissionSelected",
    "PmenuSbar:PiPermissionNormal",
    "PmenuThumb:PiPermissionNormal",
    "StatusLine:PiPermissionNormal",
    "StatusLineNC:PiPermissionNormal",
    "WinSeparator:PiPermissionNormal",
    "FloatBorder:PiPermissionNormal",
  }, ",")
end

function PermissionPanel.new(chat, deps)
  return setmetatable({
    chat = chat,
    namespace = deps.namespace,
    queue = {},
    current = nil,
    selected = 1,
    expanded = false,
    body_offset = 1,
    body_lines = {},
    body_budget = 1,
    return_win = nil,
    return_mode = nil,
    return_guicursor = nil,
    key_namespace = vim.api.nvim_create_namespace("pi.nvim.permission.keys." .. vim.fn.sha256(chat.root):sub(1, 12)),
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
  self:_render()
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
  self.chat:_layout()
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
    if self.chat.permission_win and vim.api.nvim_win_is_valid(self.chat.permission_win) then
      pcall(vim.api.nvim_set_current_win, self.chat.permission_win)
    end
    self:_handle_key(typed)
    -- The permission panel is a focus trap. Unrecognized typed keys are ignored
    -- instead of leaking into Normal mode or another plugin.
    return ""
  end, self.key_namespace)
end

function PermissionPanel:_remove_key_capture()
  vim.on_key(nil, self.key_namespace)
end

function PermissionPanel:_install_mappings(buf)
  local function map(modes, keys, callback)
    for _, key in ipairs(keys) do
      vim.keymap.set(modes, key, callback, {
        buffer = buf,
        silent = true,
        nowait = true,
        noremap = true,
      })
    end
  end

  -- These mappings are a fallback for generated/non-typed input. Real user
  -- input is captured by vim.on_key so later plugin mappings cannot steal it.
  map({ "n", "i" }, { "k", "<Up>" }, function()
    self:_select(-1)
  end)
  map({ "n", "i" }, { "j", "<Down>" }, function()
    self:_select(1)
  end)
  map({ "n", "i" }, { "<Esc>" }, function()
    self:_block()
  end)
  map({ "n", "i" }, { "<CR>" }, function()
    self:_resolve_selected()
  end)
  map({ "n", "i" }, { "<C-q>" }, function()
    self:exit_to_normal()
  end)
  map({ "n", "i" }, { "e" }, function()
    self:_toggle_expanded()
  end)
  map({ "n", "i" }, { "<C-d>", "<PageDown>" }, function()
    self:_scroll(math.max(1, math.floor(self.body_budget / 2)))
  end)
  map({ "n", "i" }, { "<C-u>", "<PageUp>" }, function()
    self:_scroll(-math.max(1, math.floor(self.body_budget / 2)))
  end)
end

function PermissionPanel:_ensure_buffer()
  local chat = self.chat
  if chat.permission_buf and vim.api.nvim_buf_is_valid(chat.permission_buf) then
    return chat.permission_buf
  end

  chat.permission_buf = vim.api.nvim_create_buf(false, true)
  local ok = pcall(vim.api.nvim_buf_set_name, chat.permission_buf, "Pi Permission · " .. vim.fs.basename(chat.root))
  if not ok then
    vim.api.nvim_buf_set_name(chat.permission_buf, "Pi Permission · " .. vim.fn.sha256(chat.root):sub(1, 6))
  end
  vim.b[chat.permission_buf].pi_kind = "permission"
  vim.b[chat.permission_buf].pi_root = chat.root
  isolate_buffer(chat.permission_buf)
  self:_install_mappings(chat.permission_buf)
  return chat.permission_buf
end

function PermissionPanel:_ensure_window()
  local chat = self.chat
  if chat.permission_win and vim.api.nvim_win_is_valid(chat.permission_win) then
    return chat.permission_win
  end
  if not chat.win or not vim.api.nvim_win_is_valid(chat.win) then
    return nil
  end

  local buf = self:_ensure_buffer()
  chat.permission_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = chat.win,
    row = 0,
    col = 0,
    width = math.max(1, vim.api.nvim_win_get_width(chat.win)),
    height = 1,
    style = "minimal",
    focusable = true,
    zindex = 60,
  })
  isolate_window(chat.permission_win)
  vim.wo[chat.permission_win].fillchars = "eob: "
  vim.wo[chat.permission_win].winblend = 0
  return chat.permission_win
end

function PermissionPanel:_close_window()
  local chat = self.chat
  self:_remove_key_capture()
  if chat.permission_win and vim.api.nvim_win_is_valid(chat.permission_win) then
    vim.api.nvim_win_close(chat.permission_win, true)
  end
  chat.permission_win = nil
end

function PermissionPanel:_focus()
  local win = self:_ensure_window()
  if not win then
    return
  end
  isolate_buffer(self.chat.permission_buf)
  isolate_window(win)
  vim.o.guicursor = "a:PiPermissionCursor"
  vim.api.nvim_set_current_win(win)
  -- Window-enter plugins have run by this point, so reassert ownership of the
  -- picker keys after they had a chance to install buffer-local mappings.
  self:_install_mappings(self.chat.permission_buf)
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
    self:_render()
    return
  end

  self.return_win = vim.api.nvim_get_current_win()
  self.return_mode = vim.api.nvim_get_mode().mode
  self.return_guicursor = vim.o.guicursor
  self:_advance()
end

function PermissionPanel:_advance()
  self.current = table.remove(self.queue, 1)
  self.selected = 1
  self.expanded = false
  self.body_offset = 1
  if not self.current then
    self:_close_window()
    self.chat:_layout()
    self:_restore_focus()
    return
  end

  self.chat:_close_command_menu()
  self:_ensure_window()
  self.chat:_layout()
  self:_focus()
end

function PermissionPanel:_restore_focus()
  local win = self.return_win
  local mode = self.return_mode
  local guicursor = self.return_guicursor
  self.return_win = nil
  self.return_mode = nil
  self.return_guicursor = nil
  if guicursor ~= nil then
    vim.o.guicursor = guicursor
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  if win == self.chat.input_win and mode and mode:sub(1, 1) == "i" then
    vim.cmd("startinsert")
  end
end

function PermissionPanel:exit_to_normal()
  if not self:active() then
    return
  end
  local target = self.chat.win and vim.api.nvim_win_is_valid(self.chat.win) and self.chat.win or self.return_win
  self:cancel_all(true, target)
  self.chat:_layout()
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
    self:_close_window()
    return
  end
  local pending = {}
  if self.current then
    table.insert(pending, self.current)
  end
  vim.list_extend(pending, self.queue)
  self.current = nil
  self.queue = {}
  self:_close_window()
  for _, item in ipairs(pending) do
    if item.callback then
      item.callback(false)
    end
  end
  if self.return_guicursor ~= nil then
    vim.o.guicursor = self.return_guicursor
    self.return_guicursor = nil
  end
  local return_win = target_win or self.return_win
  if force_normal and return_win and vim.api.nvim_win_is_valid(return_win) then
    vim.api.nvim_set_current_win(return_win)
    vim.cmd("stopinsert")
  end
  self.return_win = nil
  self.return_mode = nil
end

function PermissionPanel:_scroll(delta)
  local maximum = math.max(1, #self.body_lines - self.body_budget + 1)
  local next_offset = math.max(1, math.min(maximum, self.body_offset + delta))
  if next_offset ~= self.body_offset then
    self.body_offset = next_offset
    self:_render()
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
    local cwd = vim.fn.fnamemodify(self.chat.root, ":~")
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
      selected_start = extra and extra.selected_start,
      selected_end = extra and extra.selected_end,
      marker_start = extra and extra.marker_start,
      marker_end = extra and extra.marker_end,
      detail_start = extra and extra.detail_start,
      detail_end = extra and extra.detail_end,
      detail_highlight = extra and extra.detail_highlight,
      selected_highlight = extra and extra.selected_highlight,
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
    local row = add(line, "choice", {
      start_col = 1,
      selected_start = selected and 0 or nil,
      selected_end = selected and #line or nil,
      marker_start = selected and 1 or nil,
      marker_end = selected and (1 + #marker) or nil,
      detail_start = 1 + #marker + 1,
      detail_end = #line,
      detail_highlight = selected and selected_highlight or choice_highlight,
      selected_highlight = selected_highlight,
      marker_highlight = selected_highlight,
    })
    if selected then
      self.selected_row = row + 1
    end
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

function PermissionPanel:_render(width, height)
  if not self.current then
    return
  end
  local chat = self.chat
  local win = self:_ensure_window()
  if not win then
    return
  end
  width = width or vim.api.nvim_win_get_width(win)
  height = height or vim.api.nvim_win_get_height(win)
  local lines, marks = self:_compose(width, height)
  local buf = self:_ensure_buffer()
  isolate_buffer(buf)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, mark in ipairs(marks) do
    local selected_line = mark.selected_start ~= nil and mark.selected_end ~= nil
    vim.api.nvim_buf_set_extmark(buf, self.namespace, mark.row, 0, {
      line_hl_group = selected_line and (mark.selected_highlight or "PiPermissionSelected") or "PiPermissionNormal",
      priority = selected_line and 145 or 80,
    })
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
    local group = groups[mark.kind]
    if group and mark.end_col > mark.start_col then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, mark.row, mark.start_col, {
        end_col = mark.end_col,
        hl_group = group,
        priority = 130,
      })
    end
    if mark.selected_start ~= nil and mark.selected_end ~= nil then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, mark.row, mark.selected_start, {
        end_col = mark.selected_end,
        hl_group = mark.selected_highlight or "PiPermissionSelected",
        priority = 150,
      })
    end
    if mark.detail_start and mark.detail_end and mark.detail_end > mark.detail_start then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, mark.row, mark.detail_start, {
        end_col = mark.detail_end,
        hl_group = mark.detail_highlight,
        priority = 155,
      })
    end
    if mark.marker_start and mark.marker_end then
      vim.api.nvim_buf_set_extmark(buf, self.namespace, mark.row, mark.marker_start, {
        end_col = mark.marker_end,
        hl_group = mark.marker_highlight or "PiPermissionMarker",
        priority = 160,
      })
    end
    if mark.kind == "command" then
      highlight_shell_line(buf, self.namespace, mark.row, lines[mark.row + 1] or "")
    end
  end

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { math.max(1, self.selected_row or (#lines - 1)), 1 })
  end
end

function PermissionPanel:layout(width, input_row)
  if not self.current then
    return 0
  end
  local available = math.max(1, input_row)
  local desired = self.expanded and available or math.min(MAX_COMPACT_HEIGHT, available)
  local body_lines = self:_body(width)
  local natural = math.max(MIN_HEIGHT, 9 + #body_lines)
  local height = math.max(1, math.min(desired, natural))
  local win = self:_ensure_window()
  if not win then
    return 0
  end
  vim.api.nvim_win_set_config(win, {
    relative = "win",
    win = self.chat.win,
    row = math.max(0, input_row - height),
    col = 0,
    width = math.max(1, width),
    height = height,
    style = "minimal",
    focusable = true,
    zindex = 60,
  })
  self:_render(width, height)
  return height
end

M.PermissionPanel = PermissionPanel
return M
