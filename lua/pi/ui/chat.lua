local config = require("pi.config")
local renderer = require("pi.ui.render")
local highlights = require("pi.ui.highlights")

local M = {}
local Chat = {}
Chat.__index = Chat

local namespace = vim.api.nvim_create_namespace("pi.nvim")
local instances = setmetatable({}, { __mode = "v" })
local welcome_animation_timer = nil
local welcome_animation_frame = 0

local function update_welcome_logo_highlights()
  local welcome_logo_palette, welcome_logo_background = highlights.welcome_palette()
  if #welcome_logo_palette == 0 then
    return
  end

  for index = 1, 4 do
    local palette_index = (index + welcome_animation_frame - 2) % #welcome_logo_palette + 1
    vim.api.nvim_set_hl(0, "PiWelcomeLogo" .. index, {
      fg = welcome_logo_palette[palette_index],
      bg = welcome_logo_background,
      bold = true,
    })
  end
end

local function has_open_chat()
  for _, chat in pairs(instances) do
    if chat.is_open and chat:is_open() then
      return true
    end
  end
  return false
end

local function stop_welcome_animation()
  if welcome_animation_timer then
    welcome_animation_timer:stop()
    welcome_animation_timer:close()
    welcome_animation_timer = nil
  end
end

local function sync_welcome_animation()
  if not has_open_chat() then
    stop_welcome_animation()
    return
  end
  if welcome_animation_timer then
    return
  end

  welcome_animation_timer = vim.uv.new_timer()
  welcome_animation_timer:start(
    360,
    360,
    vim.schedule_wrap(function()
      if not has_open_chat() then
        stop_welcome_animation()
        return
      end
      local welcome_logo_palette = highlights.welcome_palette()
      welcome_animation_frame = (welcome_animation_frame + 1) % math.max(1, #welcome_logo_palette)
      update_welcome_logo_highlights()
    end)
  )
end

local function dispatch_left_mouse(chat)
  if not chat:_handle_left_mouse() then
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "n", false)
  end
end

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

local ui_group = vim.api.nvim_create_augroup("PiNvimUI", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = ui_group,
  callback = function()
    highlights.setup()
    update_welcome_logo_highlights()
  end,
})
vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = ui_group,
  callback = function()
    for _, chat in pairs(instances) do
      if chat:is_open() then
        chat:_layout()
      end
    end
  end,
})
vim.api.nvim_create_autocmd("WinScrolled", {
  group = ui_group,
  callback = function(event)
    local win = tonumber(event.match)
    for _, chat in pairs(instances) do
      if chat.win == win and chat._clamp_transcript_view then
        chat:_clamp_transcript_view()
        break
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = ui_group,
  callback = stop_welcome_animation,
})

local function text_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      table.insert(parts, block.text or "")
    end
  end
  return table.concat(parts, "\n")
end

local function format_count(value)
  value = tonumber(value) or 0
  if value < 1000 then
    return tostring(math.floor(value))
  elseif value < 10000 then
    return ("%.1fk"):format(value / 1000)
  elseif value < 1000000 then
    return ("%dk"):format(math.floor(value / 1000 + 0.5))
  elseif value < 10000000 then
    return ("%.1fM"):format(value / 1000000)
  end
  return ("%dM"):format(math.floor(value / 1000000 + 0.5))
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
}

local status_padding = "  "

local function available_commands()
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

function M.complete(findstart, base)
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
  local commands = available_commands()
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

function Chat.new(root)
  highlights.setup()
  update_welcome_logo_highlights()
  local chat = setmetatable({
    root = root,
    buf = nil,
    win = nil,
    input_buf = nil,
    input_win = nil,
    command_buf = nil,
    command_win = nil,
    command_matches = {},
    command_selected = 1,
    command_first = 1,
    status_buf = nil,
    status_win = nil,
    transcript_width = nil,
    history_loaded = false,
    items = {},
    tools_by_id = {},
    tool_ranges = {},
    process_ranges = {},
    streaming_assistant = nil,
    tools_expanded = false,
    hide_thinking = true,
    process_expanded = false,
    commands = {},
    queue = { steering = {}, followUp = {} },
    render_pending = false,
    animation_frame = 0,
    animation_timer = nil,
    activity_started_at = nil,
    path = root,
    activity = "starting",
    model = "loading",
    thinking = "-",
    auto_compaction = true,
    stats = {
      tokens = {},
      contextUsage = {},
      cost = 0,
    },
  }, Chat)
  instances[root] = chat
  return chat
end

function Chat:is_open()
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and self.input_win ~= nil
    and vim.api.nvim_win_is_valid(self.input_win)
    and self.status_win ~= nil
    and vim.api.nvim_win_is_valid(self.status_win)
end

function Chat:_stop_animation()
  if self.animation_timer then
    self.animation_timer:stop()
    self.animation_timer:close()
    self.animation_timer = nil
  end
end

function Chat:_is_active()
  return self.activity ~= "idle"
    and self.activity ~= "starting"
    and self.activity ~= "stopped"
    and self.activity ~= "error"
end

function Chat:_process_is_active()
  if self:_is_active() or self.streaming_assistant then
    return true
  end
  for index = #self.items, 1, -1 do
    local item = self.items[index]
    if item.type == "user" then
      break
    elseif item.type == "tool" and item.state == "pending" then
      return true
    end
  end
  return false
end

function Chat:_activity_text()
  if self:_is_active() then
    local elapsed = self.activity_started_at and ((vim.uv.hrtime() - self.activity_started_at) / 1000000000) or 0
    local duration = renderer.format_elapsed(elapsed)
    local labels = {
      working = "Thinking",
      compacting = "Compacting",
    }
    local label = labels[self.activity] or self.activity:gsub("^%l", string.upper)
    return label .. " · " .. duration
  end
  return self.activity
end

function Chat:_input_frame(width)
  width = math.max(1, math.floor(width or 1))
  local active = self:_is_active()
  local base_highlight = self.activity == "error" and "PiInputBorderError"
    or active and "PiInputBorderMuted"
    or "PiInputBorder"
  local corner_highlight = self.activity == "error" and "PiInputCornerError"
    or active and "PiInputCornerMuted"
    or "PiInputCorner"
  local cell_highlights = {}

  if active and width > 1 then
    local travel = math.max(1, math.floor((width - 1) / 2))
    local period = travel * 2
    local step = (self.animation_frame or 0) * 2 % period
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
  local label = active and (" " .. self:_activity_text() .. " ") or self.activity == "error" and " Error " or nil
  if not label then
    return top, line_chunks(1, width, "▁"), base_highlight, corner_highlight
  end

  label = truncate_display(label, width)
  local label_width = vim.api.nvim_strwidth(label)
  local left_width = math.floor((width - label_width) / 2)
  local bottom = line_chunks(1, left_width, "▁")
  append_chunk(bottom, label, self.activity == "error" and "PiInputBorderError" or "PiInputActivity")
  for index = left_width + label_width + 1, width do
    append_chunk(bottom, "▁", cell_highlights[index])
  end
  return top, bottom, base_highlight, corner_highlight
end

function Chat:_input_window_config(row, width, height)
  local top, bottom, border_highlight, corner_highlight = self:_input_frame(width)
  return {
    relative = "win",
    win = self.win,
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

function Chat:_sync_animation()
  if not self:_is_active() or not self:is_open() then
    self:_stop_animation()
    return
  end
  if self.animation_timer then
    return
  end
  self.animation_timer = vim.uv.new_timer()
  self.animation_timer:start(
    120,
    110,
    vim.schedule_wrap(function()
      if not self:_is_active() or not self:is_open() then
        self:_stop_animation()
        return
      end
      self.animation_frame = self.animation_frame + 1
      self:_layout()
    end)
  )
end

function Chat:close()
  self:_stop_animation()
  for _, win in ipairs({ self.command_win, self.status_win, self.input_win, self.win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  self.command_win = nil
  self.command_matches = {}
  self.status_win = nil
  self.input_win = nil
  self.win = nil
  sync_welcome_animation()
end

function Chat:set_path(path)
  if not path or path == "" or path:find("://", 1, true) then
    return
  end
  self.path = vim.fs.normalize(path)
  self:_render_status()
end

function Chat:set_activity(activity)
  local was_active = self:_is_active()
  local previous = self.activity
  self.activity = activity or "idle"
  if self:_is_active() then
    if not was_active or previous ~= self.activity or not self.activity_started_at then
      self.activity_started_at = vim.uv.hrtime()
      self.animation_frame = 0
    end
  else
    self.activity_started_at = nil
  end
  self:_sync_animation()
  self:_layout()
  if was_active ~= self:_is_active() and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    self:_render_transcript()
  end
end

function Chat:update_state(state)
  state = state or {}
  if state.model then
    self.model = state.model.id or state.model.name or self.model
  end
  self.thinking = state.thinkingLevel or self.thinking
  if state.autoCompactionEnabled ~= nil then
    self.auto_compaction = state.autoCompactionEnabled
  end
  if state.isCompacting then
    self.activity = "compacting"
  elseif state.isStreaming then
    self.activity = "working"
  else
    self.activity = "idle"
  end
  if self:_is_active() and not self.activity_started_at then
    self.activity_started_at = vim.uv.hrtime()
    self.animation_frame = 0
  elseif not self:_is_active() then
    self.activity_started_at = nil
  end
  self:_sync_animation()
  self:_update_input_chrome()
  self:_render_status()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    self:_render_transcript()
  end
end

function Chat:update_stats(stats)
  self.stats = stats or self.stats
  self:_render_status()
end

function Chat:set_queue(queue)
  self.queue = queue or { steering = {}, followUp = {} }
  self:_update_input_chrome()
end

function Chat:set_commands(commands)
  self.commands = commands or {}
  if self:_command_menu_visible() then
    self:_update_command_menu()
  end
end

function Chat:_command_completion_context()
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    return nil
  end
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(self.input_win)
  local line = vim.api.nvim_buf_get_lines(self.input_buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local before_cursor = line:sub(1, cursor[2])
  local leading, base = before_cursor:match("^(%s*)(/[%w:_-]*)$")
  if not base or line:sub(cursor[2] + 1):match("%S") then
    return nil
  end

  local matches = M.complete(0, base)
  if #matches == 0 then
    return nil
  end
  return #leading + 1, matches, base
end

function Chat:_command_menu_visible()
  return self.command_win ~= nil and vim.api.nvim_win_is_valid(self.command_win)
end

function Chat:_ensure_command_buffer()
  if self.command_buf and vim.api.nvim_buf_is_valid(self.command_buf) then
    return self.command_buf
  end

  self.command_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.command_buf, "commands", self.root)
  vim.bo[self.command_buf].buftype = "nofile"
  vim.bo[self.command_buf].bufhidden = "hide"
  vim.bo[self.command_buf].swapfile = false
  vim.bo[self.command_buf].filetype = "pi_commands"
  vim.bo[self.command_buf].modifiable = false
  return self.command_buf
end

function Chat:_close_command_menu()
  if self:_command_menu_visible() then
    vim.api.nvim_win_close(self.command_win, true)
  end
  self.command_win = nil
  self.command_matches = {}
  self.command_selected = 1
  self.command_first = 1
  self.command_start_col = nil
  self.command_base = nil
end

function Chat:_render_command_menu(width, height, first)
  local buf = self:_ensure_command_buffer()
  local marker_width = 2
  local content_width = math.max(1, width - marker_width)
  local longest_command = 0
  for _, match in ipairs(self.command_matches) do
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
  local last = math.min(#self.command_matches, first + height - 1)
  for index = first, last do
    local match = self.command_matches[index]
    local selected = index == self.command_selected
    local marker = selected and "› " or "  "
    local command = truncate_display(match.abbr, command_width)
    local command_padding = string.rep(" ", math.max(0, command_width - vim.api.nvim_strwidth(command)))
    local separator = show_description and "  " or ""
    local description = show_description and truncate_display(match.menu, description_width) or ""
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
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  for row_index, row in ipairs(rows) do
    local row_number = row_index - 1
    if row.selected then
      vim.api.nvim_buf_set_extmark(buf, namespace, row_number, 0, {
        line_hl_group = "PiCommandSelected",
        priority = 80,
      })
      vim.api.nvim_buf_set_extmark(buf, namespace, row_number, 0, {
        end_col = #"›",
        hl_group = "PiCommandMarker",
        priority = 150,
      })
    end
    if row.command_name_end > 0 then
      vim.api.nvim_buf_set_extmark(buf, namespace, row_number, row.command_start, {
        end_col = row.command_start + row.command_name_end,
        hl_group = row.selected and "PiCommandNameSelected" or "PiCommandName",
        priority = 120,
      })
    end
    if #row.command > row.command_name_end then
      vim.api.nvim_buf_set_extmark(buf, namespace, row_number, row.command_start + row.command_name_end, {
        end_col = row.command_start + #row.command,
        hl_group = "PiCommandHint",
        priority = 125,
      })
    end
    if row.description_end > row.description_start then
      vim.api.nvim_buf_set_extmark(buf, namespace, row_number, row.description_start, {
        end_col = row.description_end,
        hl_group = row.selected and "PiCommandDescriptionSelected" or "PiCommandDescription",
        priority = 120,
      })
    end
    for _, position in ipairs(row.match_positions) do
      local start_col = row.command_start + #"/" + position
      if start_col < row.command_start + row.command_name_end then
        vim.api.nvim_buf_set_extmark(buf, namespace, row_number, start_col, {
          end_col = start_col + 1,
          hl_group = "PiCommandMatch",
          priority = 170,
        })
      end
    end
  end
end

function Chat:_layout_command_menu()
  if not self:_command_menu_visible() or #self.command_matches == 0 then
    return false
  end
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    self:_close_command_menu()
    return false
  end
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    self:_close_command_menu()
    return false
  end

  local input_config = vim.api.nvim_win_get_config(self.input_win)
  local input_row = math.floor(tonumber(input_config.row) or 0)
  local available_height = math.max(0, input_row)
  local height = math.min(#self.command_matches, 12, available_height)
  if height < 1 then
    self:_close_command_menu()
    return false
  end

  self.command_selected = math.max(1, math.min(self.command_selected, #self.command_matches))
  local maximum_first = math.max(1, #self.command_matches - height + 1)
  local first = math.max(1, math.min(self.command_first or 1, maximum_first))
  if self.command_selected < first then
    first = self.command_selected
  elseif self.command_selected >= first + height then
    first = self.command_selected - height + 1
  end
  self.command_first = first

  local width = math.max(1, vim.api.nvim_win_get_width(self.win) - 2)
  vim.api.nvim_win_set_config(self.command_win, {
    relative = "win",
    win = self.win,
    row = input_row - height,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    zindex = 52,
  })
  self:_render_command_menu(width, height, first)
  return true
end

function Chat:_open_command_menu()
  if not self:_command_menu_visible() then
    local buf = self:_ensure_command_buffer()
    self.command_win = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = self.win,
      row = 0,
      col = 0,
      width = 1,
      height = 1,
      style = "minimal",
      focusable = false,
      zindex = 52,
    })
    vim.wo[self.command_win].wrap = false
    vim.wo[self.command_win].cursorline = false
    vim.wo[self.command_win].number = false
    vim.wo[self.command_win].relativenumber = false
    vim.wo[self.command_win].signcolumn = "no"
    vim.wo[self.command_win].foldcolumn = "0"
    vim.wo[self.command_win].fillchars = "eob: "
    vim.wo[self.command_win].winblend = 0
    vim.wo[self.command_win].winbar = ""
    vim.wo[self.command_win].winhighlight = table.concat({
      "Normal:PiCommandMenu",
      "NormalNC:PiCommandMenu",
      "EndOfBuffer:PiCommandMenu",
      "WinSeparator:PiCommandMenu",
    }, ",")
  end
  return self:_layout_command_menu()
end

function Chat:_update_command_menu()
  if vim.api.nvim_get_current_win() ~= self.input_win then
    self:_close_command_menu()
    return false
  end
  local start_col, matches, base = self:_command_completion_context()
  if not start_col then
    self:_close_command_menu()
    return false
  end
  if #matches == 1 and matches[1].word == base then
    self:_close_command_menu()
    return false
  end

  local selected_word = self.command_matches[self.command_selected] and self.command_matches[self.command_selected].word
  self.command_matches = matches
  self.command_selected = 1
  if selected_word then
    for index, match in ipairs(matches) do
      if match.word == selected_word then
        self.command_selected = index
        break
      end
    end
  end
  self.command_first = 1
  self.command_start_col = start_col
  self.command_base = base
  return self:_open_command_menu()
end

function Chat:_show_command_completion()
  return self:_update_command_menu()
end

function Chat:_select_command(delta)
  if not self:_command_menu_visible() or #self.command_matches == 0 then
    return false
  end
  local count = #self.command_matches
  self.command_selected = (self.command_selected - 1 + delta) % count + 1
  self:_layout_command_menu()
  return true
end

function Chat:_accept_command_completion()
  if not self:_command_menu_visible() then
    return false
  end
  local match = self.command_matches[self.command_selected]
  local start_col = self.command_start_col
  if not match or not start_col then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(self.input_win)
  vim.api.nvim_buf_set_text(
    self.input_buf,
    cursor[1] - 1,
    start_col - 1,
    cursor[1] - 1,
    cursor[2],
    { match.word .. " " }
  )
  vim.api.nvim_win_set_cursor(self.input_win, { cursor[1], start_col - 1 + #match.word + 1 })
  self:_close_command_menu()
  return true
end

function Chat:_update_input_chrome()
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
  self:_layout()
end

function Chat:_status_text(width)
  local context_usage = self.stats.contextUsage or {}
  local steering = #(self.queue.steering or {})
  local follow_up = #(self.queue.followUp or {})
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
  local line, right_start = compose_line(self.model .. " · " .. self.thinking, right, content_width)
  return { status_padding .. line }, { #status_padding + right_start }
end

function Chat:_render_status()
  if not self.status_buf or not vim.api.nvim_buf_is_valid(self.status_buf) then
    return
  end
  local width = self.status_win
      and vim.api.nvim_win_is_valid(self.status_win)
      and vim.api.nvim_win_get_width(self.status_win)
    or 80
  local lines, right_starts = self:_status_text(width)
  vim.bo[self.status_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.status_buf, 0, -1, false, lines)
  vim.bo[self.status_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.status_buf, namespace, 0, -1)

  local function highlight(row, start_col, end_col, group, priority)
    if end_col <= start_col then
      return
    end
    vim.api.nvim_buf_set_extmark(self.status_buf, namespace, row, start_col, {
      end_col = end_col,
      hl_group = group,
      priority = priority or 100,
    })
  end

  highlight(0, #status_padding, math.min(right_starts[1], #lines[1]), "PiStatusModel")
  local thinking_start = lines[1]:find(self.thinking, #status_padding + 1, true)
  if thinking_start then
    highlight(0, thinking_start - 1, thinking_start - 1 + #self.thinking, "PiStatusThinking", 130)
  end

  local right_highlight = "PiStatusContext"
  if #(self.queue.steering or {}) > 0 or #(self.queue.followUp or {}) > 0 then
    right_highlight = "PiStatusWorking"
  else
    local percent = tonumber((self.stats.contextUsage or {}).percent)
    if percent and percent > 90 then
      right_highlight = "PiStatusError"
    elseif percent and percent > 70 then
      right_highlight = "PiStatusWarning"
    end
  end
  highlight(0, math.min(right_starts[1], #lines[1]), #lines[1], right_highlight, 140)
end

function Chat:_desired_input_height()
  local maximum = math.max(3, config.get().chat.max_input_height or 8)
  return math.max(3, math.min(vim.api.nvim_buf_line_count(self.input_buf) + 2, maximum))
end

function Chat:_layout_main()
  if self.position ~= "float" or not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local options = config.get().chat.float or {}
  local available_width = math.max(42, vim.o.columns - 4)
  local available_height = math.max(12, vim.o.lines - vim.o.cmdheight - 4)
  local width = math.min(available_width, math.max(42, math.floor(vim.o.columns * (options.width or 0.84))))
  local height = math.min(available_height, math.max(12, math.floor(vim.o.lines * (options.height or 0.86))))
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = options.border or "rounded",
    title = { { " pi ", "PiPanelTitle" } },
    title_pos = "center",
    zindex = 40,
  })
end

function Chat:_layout()
  self:_layout_main()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  if not self.status_win or not vim.api.nvim_win_is_valid(self.status_win) then
    return
  end

  local width = vim.api.nvim_win_get_width(self.win)
  local height = vim.api.nvim_win_get_height(self.win)
  local transcript_width_changed = self.transcript_width ~= width
  self.transcript_width = width
  local footer_height = 1
  local available_input = math.max(1, height - footer_height - 4)
  local input_height = math.min(self:_desired_input_height(), available_input)
  local input_row = math.max(0, height - footer_height - input_height - 2)
  local footer_row = math.max(0, height - footer_height)

  local input_config = self:_input_window_config(input_row, math.max(1, width - 4), input_height)
  vim.api.nvim_win_set_config(self.input_win, input_config)
  vim.api.nvim_win_set_config(self.status_win, {
    relative = "win",
    win = self.win,
    row = footer_row,
    col = 0,
    width = width,
    height = footer_height,
    style = "minimal",
    focusable = false,
    zindex = 51,
  })
  if self:_command_menu_visible() then
    self:_layout_command_menu()
  end

  local overlay_height = input_height + footer_height + 2
  local overlay_changed = self.overlay_height ~= overlay_height
  self.overlay_height = overlay_height
  self:_render_status()
  if overlay_changed or transcript_width_changed then
    self:_render_transcript()
  end
end

function Chat:_resize_input()
  self:_layout()
end

function Chat:set_input(text)
  self:_close_command_menu()
  local buf = self:_ensure_input_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
  self:_resize_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    self:_focus_input()
    local last = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    vim.api.nvim_win_set_cursor(self.input_win, { last, #line })
  end
end

function Chat:_focus_input()
  if not self.input_win or not vim.api.nvim_win_is_valid(self.input_win) then
    return
  end
  vim.api.nvim_set_current_win(self.input_win)
  vim.cmd("startinsert")
end

function Chat:_ensure_input_buffer()
  if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
    isolate_input_completion(self.input_buf)
    return self.input_buf
  end

  self.input_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.input_buf, "prompt", self.root)
  vim.bo[self.input_buf].buftype = "nofile"
  vim.bo[self.input_buf].bufhidden = "hide"
  vim.bo[self.input_buf].swapfile = false
  isolate_input_completion(self.input_buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = ui_group,
    buffer = self.input_buf,
    callback = function(event)
      self:_resize_input()
      if event.event == "TextChangedI" then
        vim.schedule(function()
          if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
            self:_update_command_menu()
          end
        end)
      else
        self:_close_command_menu()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave" }, {
    group = ui_group,
    buffer = self.input_buf,
    callback = function()
      self:_close_command_menu()
    end,
  })

  local function submit(behavior)
    local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
    local prompt = vim.trim(table.concat(lines, "\n"))
    if prompt == "" then
      return
    end
    self:_close_command_menu()
    vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
    self:_resize_input()
    vim.api.nvim_win_set_cursor(self.input_win, { 1, 0 })
    require("pi").submit(prompt, self.root, behavior)
  end

  local function feed(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
  end

  vim.keymap.set("n", "<CR>", function()
    submit(nil)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    if self:_accept_command_completion() then
      return
    end
    submit(nil)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<M-CR>", function()
    submit("followUp")
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<Tab>", function()
    if self:_command_menu_visible() then
      self:_select_command(1)
      return
    end
    local line = vim.api.nvim_get_current_line()
    if line:match("^%s*/") and self:_update_command_menu() then
      return
    end
    feed("<Tab>")
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<Down>", function()
    if not self:_select_command(1) then
      feed("<Down>")
    end
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<Up>", function()
    if not self:_select_command(-1) then
      feed("<Up>")
    end
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<C-n>", function()
    if not self:_select_command(1) then
      feed("<C-n>")
    end
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<Esc>", function()
    if self:_command_menu_visible() then
      self:_close_command_menu()
      return
    end
    if self.activity ~= "idle" and self.activity ~= "starting" then
      require("pi").abort(self.root)
      return
    end
    feed("<Esc>")
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    require("pi").abort(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-l>", function()
    require("pi").select_model(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    require("pi").cycle_model(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<C-p>", function()
    if self:_select_command(-1) then
      return
    end
    require("pi").cycle_model(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pi").cycle_thinking_level(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set("i", "<S-Tab>", function()
    if self:_select_command(-1) then
      return
    end
    require("pi").cycle_thinking_level(self.root)
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-o>", function()
    self:toggle_tools()
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    self:toggle_thinking()
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-x>", function()
    self:copy_last_assistant()
  end, { buffer = self.input_buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<LeftMouse>", function()
    dispatch_left_mouse(self)
  end, { buffer = self.input_buf, silent = true })
  return self.input_buf
end

function Chat:_ensure_status_buffer()
  if self.status_buf and vim.api.nvim_buf_is_valid(self.status_buf) then
    return self.status_buf
  end
  self.status_buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.status_buf, "status", self.root)
  vim.bo[self.status_buf].buftype = "nofile"
  vim.bo[self.status_buf].bufhidden = "hide"
  vim.bo[self.status_buf].swapfile = false
  vim.bo[self.status_buf].filetype = "pi_status"
  vim.bo[self.status_buf].modifiable = false
  return self.status_buf
end

function Chat:_ensure_buffer()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  name_buffer(self.buf, "chat", self.root)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "markdown"
  vim.bo[self.buf].modifiable = false

  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, silent = true })
  for _, key in ipairs({ "i", "a" }) do
    vim.keymap.set("n", key, function()
      self:_focus_input()
    end, { buffer = self.buf, silent = true })
  end
  vim.keymap.set("n", "<C-c>", function()
    require("pi").abort(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-l>", function()
    require("pi").select_model(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-p>", function()
    require("pi").cycle_model(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<S-Tab>", function()
    require("pi").cycle_thinking_level(self.root)
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-o>", function()
    self:toggle_tools()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-t>", function()
    self:toggle_thinking()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<C-x>", function()
    self:copy_last_assistant()
  end, { buffer = self.buf, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function()
    dispatch_left_mouse(self)
  end, { buffer = self.buf, silent = true })
  return self.buf
end

local function style_window(win, normal_group)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winhighlight = ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,WinSeparator:PiPanelBorder,FloatBorder:PiPanelBorder"):format(
    normal_group,
    normal_group,
    normal_group
  )
end

function Chat:set_position(position)
  if not vim.tbl_contains({ "right", "bottom", "tab", "float" }, position) then
    error("pi.nvim: layout must be right, bottom, tab, or float")
  end
  local reopen = self:is_open()
  if reopen then
    self:close()
  end
  self.position = position
  if reopen then
    self:open()
  end
end

function Chat:open(focus_input)
  local buf = self:_ensure_buffer()
  local input_buf = self:_ensure_input_buffer()
  local status_buf = self:_ensure_status_buffer()
  if self:is_open() then
    if focus_input ~= false then
      self:_focus_input()
    end
    return
  end

  self:close()
  local chat = config.get().chat
  self.position = self.position or chat.position
  if self.position == "tab" then
    vim.cmd("tabnew")
    self.win = vim.api.nvim_get_current_win()
  elseif self.position == "float" then
    local width = math.max(1, vim.o.columns - 4)
    local height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
    self.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 1,
      col = 2,
      width = width,
      height = height,
      style = "minimal",
      border = (chat.float or {}).border or "rounded",
      zindex = 40,
    })
  elseif self.position == "bottom" then
    vim.cmd("botright new")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(self.win, math.max(10, math.floor(vim.o.lines * chat.height)))
  elseif self.position == "right" then
    vim.cmd("botright vnew")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(self.win, math.max(42, math.floor(vim.o.columns * chat.width)))
  else
    error("pi.nvim: chat.position must be 'right', 'bottom', 'tab', or 'float'")
  end
  vim.api.nvim_win_set_buf(self.win, buf)
  style_window(self.win, "PiCanvasNormal")
  vim.wo[self.win].cursorline = false
  vim.wo[self.win].winbar = ""

  local width = vim.api.nvim_win_get_width(self.win)
  self.input_win = vim.api.nvim_open_win(input_buf, false, self:_input_window_config(0, math.max(1, width - 4), 3))
  style_window(self.input_win, "PiInputNormal")
  vim.wo[self.input_win].cursorline = false
  vim.wo[self.input_win].spell = false
  vim.wo[self.input_win].winblend = 0
  vim.wo[self.input_win].winbar = " "

  self.status_win = vim.api.nvim_open_win(status_buf, false, {
    relative = "win",
    win = self.win,
    row = 0,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 51,
  })
  style_window(self.status_win, "PiStatusNormal")
  vim.wo[self.status_win].wrap = false
  vim.wo[self.status_win].winbar = ""

  self:_update_input_chrome()
  self:_sync_animation()
  sync_welcome_animation()
  if focus_input ~= false then
    self:_focus_input()
  end
end

function Chat:_with_modifiable(callback)
  local buf = self:_ensure_buffer()
  vim.bo[buf].modifiable = true
  callback(buf)
  vim.bo[buf].modifiable = false
end

function Chat:_clamp_transcript_view()
  if
    not self.win
    or not vim.api.nvim_win_is_valid(self.win)
    or not self.buf
    or not vim.api.nvim_buf_is_valid(self.buf)
    or vim.api.nvim_win_get_buf(self.win) ~= self.buf
  then
    return false
  end

  local clamped = false
  vim.api.nvim_win_call(self.win, function()
    local last_line = vim.api.nvim_buf_line_count(self.buf)
    if vim.fn.line("w$") ~= last_line then
      return
    end

    local position = vim.fn.screenpos(self.win, last_line, 1)
    local window_position = vim.fn.win_screenpos(self.win)
    local relative_row = position.row - window_position[1] + 1
    local view = vim.fn.winsaveview()
    local has_scrolled_origin = view.topline > 1 or (view.skipcol or 0) > 0
    if position.row > 0 and relative_row < vim.api.nvim_win_get_height(self.win) and has_scrolled_origin then
      vim.cmd("normal! Gzb")
      clamped = true
    end
  end)
  return clamped
end

function Chat:_render_transcript()
  local follow_output = true
  local previous_row = 1
  if self.win and vim.api.nvim_win_is_valid(self.win) and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    previous_row = vim.api.nvim_win_get_cursor(self.win)[1]
    follow_output = previous_row >= vim.api.nvim_buf_line_count(self.buf) - 1
  end

  local width = self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or 80
  local lines, marks, tool_ranges, process_ranges = renderer.render(self.items, {
    hide_thinking = self.hide_thinking,
    tools_expanded = self.tools_expanded,
    collapse_processes = true,
    process_expanded = self.process_expanded,
    process_active = self:_process_is_active(),
    width = width,
    welcome = {
      model = self.model,
      thinking = self.thinking,
      root = self.root,
      permission = (config.get().security or {}).mode,
    },
  })
  self.tool_ranges = tool_ranges
  self.process_ranges = process_ranges
  for _ = 1, self.overlay_height or 0 do
    table.insert(lines, "")
  end
  if #lines == 0 then
    lines = { "" }
  end

  self:_with_modifiable(function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, mark in ipairs(marks) do
      if mark.line_highlight then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row, 0, {
          line_hl_group = mark.line_highlight,
          priority = mark.priority or 90,
        })
      end
      if mark.highlight and mark.end_col > mark.start_col then
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.start_col, {
          end_col = mark.end_col,
          hl_group = mark.highlight,
          priority = mark.priority or 100,
        })
      end
    end
  end)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local row = follow_output and #lines or math.min(previous_row, #lines)
    vim.api.nvim_win_set_cursor(self.win, { math.max(1, row), 0 })
  end
end

function Chat:_schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.defer_fn(function()
    self.render_pending = false
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      self:_render_transcript()
    end
  end, 25)
end

function Chat:clear()
  self.items = {}
  self.tools_by_id = {}
  self.tool_ranges = {}
  self.process_ranges = {}
  self.streaming_assistant = nil
  self:_render_transcript()
end

function Chat:add_user(text)
  table.insert(self.items, { type = "user", text = text or "" })
  self:_render_transcript()
end

function Chat:start_assistant(message)
  local item = { type = "assistant", message = message or { content = {} }, started_at = vim.uv.hrtime() }
  table.insert(self.items, item)
  self.streaming_assistant = item
  self:_render_transcript()
end

function Chat:update_assistant(message)
  if not self.streaming_assistant then
    self:start_assistant(message)
    return
  end
  self.streaming_assistant.message = message
  self:_schedule_render()
end

function Chat:end_assistant(message)
  if not self.streaming_assistant then
    self:start_assistant(message)
  else
    self.streaming_assistant.message = message
  end
  if self.streaming_assistant.started_at then
    self.streaming_assistant.duration_ms =
      math.max(1, math.floor((vim.uv.hrtime() - self.streaming_assistant.started_at) / 1000000))
  end
  self.streaming_assistant = nil
  self:_render_transcript()
end

function Chat:start_tool(id, name, args)
  local item = self.tools_by_id[id]
  if item then
    item.name = name or item.name
    item.args = args or item.args
    item.state = "pending"
  else
    item = {
      type = "tool",
      id = id,
      name = name or "tool",
      args = args or {},
      state = "pending",
      started_at = vim.uv.hrtime(),
    }
    self.tools_by_id[id] = item
    table.insert(self.items, item)
  end
  self:_render_transcript()
end

function Chat:update_tool(id, result)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.result = result
  item.state = "pending"
  self:_schedule_render()
end

function Chat:append_bash_delta(id, delta)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.bash_output = (item.bash_output or "") .. (delta or "")
  item.result = { content = { { type = "text", text = item.bash_output } } }
  self:_schedule_render()
end

function Chat:end_bash(id, data, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  data = data or {}
  local output = item.bash_output
  if not output or output == "" then
    output = data.output or ""
  end
  self:end_tool(id, {
    content = { { type = "text", text = output } },
    details = data,
  }, is_error)
end

function Chat:end_tool(id, result, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.result = result
  item.error = is_error == true
  item.state = "done"
  if item.started_at then
    item.duration_ms = math.max(1, math.floor((vim.uv.hrtime() - item.started_at) / 1000000))
  end
  self:_render_transcript()
end

function Chat:add_status(text, is_error)
  table.insert(self.items, { type = "status", text = text, error = is_error == true })
  self:_render_transcript()
end

function Chat:_tool_at_row(row)
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

function Chat:_process_at_row(row)
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

function Chat:_tool_under_cursor()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or vim.api.nvim_get_current_win() ~= self.win then
    return nil
  end
  return self:_tool_at_row(vim.api.nvim_win_get_cursor(self.win)[1])
end

function Chat:_toggle_tool(item)
  local expanded = item.expanded
  if expanded == nil then
    expanded = self.tools_expanded
  end
  item.expanded = not expanded
end

function Chat:_handle_left_mouse(mouse)
  mouse = mouse or vim.fn.getmousepos()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or mouse.winid ~= self.win then
    return false
  end
  local item = self:_tool_at_row(mouse.line)
  local process = not item and self:_process_at_row(mouse.line) or nil
  if not item and not process then
    return false
  end

  local row = math.max(1, math.min(tonumber(mouse.line) or 1, vim.api.nvim_buf_line_count(self.buf)))
  local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
  local column = math.max(0, math.min((tonumber(mouse.column) or 1) - 1, #line))
  pcall(vim.api.nvim_win_set_cursor, self.win, { row, column })
  if item then
    self:_toggle_tool(item)
    self:_render_transcript()
  else
    self:toggle_process()
  end
  return true
end

function Chat:toggle_process()
  self.process_expanded = not self.process_expanded
  self.tools_expanded = self.process_expanded
  self.hide_thinking = not self.process_expanded
  for _, candidate in ipairs(self.items) do
    if candidate.type == "tool" then
      candidate.expanded = nil
    end
  end
  self:_render_transcript()
end

function Chat:toggle_tools()
  local item = self:_tool_under_cursor()
  if item then
    self:_toggle_tool(item)
  else
    self:toggle_process()
    return
  end
  self:_render_transcript()
end

function Chat:toggle_thinking()
  self:toggle_process()
end

function Chat:copy_last_assistant()
  for index = #self.items, 1, -1 do
    local item = self.items[index]
    if item.type == "assistant" then
      local text = text_content(item.message.content)
      if text ~= "" then
        vim.fn.setreg("+", text)
        vim.notify("Copied the last Pi response", vim.log.levels.INFO, { title = "Pi" })
        return
      end
    end
  end
end

function Chat:render_history(messages)
  if self.history_loaded then
    return
  end
  self.history_loaded = true
  self.items = {}
  self.tools_by_id = {}
  self.tool_ranges = {}
  self.process_ranges = {}
  for _, message in ipairs(messages or {}) do
    if message.role == "user" then
      table.insert(self.items, { type = "user", text = text_content(message.content) })
    elseif message.role == "assistant" then
      table.insert(self.items, { type = "assistant", message = message })
      for _, block in ipairs(message.content or {}) do
        if block.type == "toolCall" then
          local item = {
            type = "tool",
            id = block.id,
            name = block.name,
            args = block.arguments or {},
            state = "pending",
          }
          self.tools_by_id[block.id] = item
          table.insert(self.items, item)
        end
      end
    elseif message.role == "toolResult" then
      local item = self.tools_by_id[message.toolCallId]
      if item then
        item.result = message
        item.error = message.isError == true
        item.state = "done"
      end
    elseif message.role == "bashExecution" then
      table.insert(self.items, {
        type = "tool",
        id = "bash-" .. tostring(message.timestamp or #self.items),
        name = "bash",
        args = { command = message.command },
        result = { content = { { type = "text", text = message.output or "" } } },
        error = (message.exitCode or 0) ~= 0,
        state = "done",
      })
    end
  end
  self:_render_transcript()
end

M.Chat = Chat
M.text_content = text_content
M.format_count = format_count
M.builtin_commands = builtin_commands
return M
