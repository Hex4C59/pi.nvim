local config = require("pi.config")

local M = {}
local Shell = {}
Shell.__index = Shell

local function right_width(columns, ratio)
  return math.min(math.max(42, math.floor(columns * ratio)), math.max(1, columns - 21))
end

local function style_window(win, normal_group)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].list = false
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

function Shell.new(deps)
  return setmetatable({
    deps = deps,
    win = nil,
    position = nil,
    title = "pi",
    permission_restore_height = nil,
    overlay_height = nil,
    transcript_height = nil,
  }, Shell)
end

function Shell:window()
  return self.win
end

function Shell:is_open()
  local input_win = self.deps.input_window()
  local status_win = self.deps.status_window()
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and input_win ~= nil
    and vim.api.nvim_win_is_valid(input_win)
    and status_win ~= nil
    and vim.api.nvim_win_is_valid(status_win)
end

function Shell:current_layout()
  return self.position or config.get().chat.position
end

function Shell:set_title(title)
  title = tostring(title or ""):gsub("[\r\n].*$", "")
  title = vim.trim(title)
  if title == "" then
    title = "pi"
  end
  self.title = vim.fn.strcharpart(title, 0, 80)
  self.deps.set_transcript_title(self.title)
  self:layout_main()
  return self.title
end

function Shell:layout_main()
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
    title = { { (" %s "):format(self.title), "PiPanelTitle" } },
    title_pos = "center",
    zindex = 40,
  })
end

function Shell:layout(options)
  options = options or {}
  if options.global_resize and self.position == "right" and self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_set_width, self.win, right_width(vim.o.columns, config.get().chat.width))
  end
  self:layout_main()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local input_win = self.deps.input_window()
  local status_win = self.deps.status_window()
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then
    return
  end
  if not status_win or not vim.api.nvim_win_is_valid(status_win) then
    return
  end

  local permission_active = self.deps.permission_active()
  local inline_menu_active = not permission_active and self.deps.inline_menu_active()
  if self.position == "bottom" then
    if permission_active then
      if not self.permission_restore_height then
        self.permission_restore_height = vim.api.nvim_win_get_height(self.win)
      end
      local maximum = math.max(10, vim.o.lines - vim.o.cmdheight - 3)
      pcall(vim.api.nvim_win_set_height, self.win, math.min(16, maximum))
    elseif self.permission_restore_height then
      pcall(vim.api.nvim_win_set_height, self.win, self.permission_restore_height)
      self.permission_restore_height = nil
    end
  end

  local width = vim.api.nvim_win_get_width(self.win)
  local height = vim.api.nvim_win_get_height(self.win)
  local transcript_width_changed = self.deps.update_transcript_width(width)
  local footer_height = 1
  local widget_hidden = permission_active or inline_menu_active or self.deps.command_menu_visible()
  local widget_budget = widget_hidden and 0 or math.max(0, height - footer_height - 7)
  local above_widget_height, below_widget_height = self.deps.measure_widgets(width, widget_budget)
  local widget_height = above_widget_height + below_widget_height
  local available_input = math.max(1, height - footer_height - 4 - widget_height)
  local input_height = math.min(self.deps.desired_input_height(), available_input)
  if permission_active then
    input_height = math.min(input_height, 3)
  end
  local input_row = math.max(0, height - footer_height - below_widget_height - input_height - 2)
  local footer_row = math.max(0, height - footer_height)
  self.deps.set_permission_height(input_row)

  local inline_menu_height = 0
  if inline_menu_active then
    inline_menu_height = math.min(self.deps.inline_menu_height(), math.max(1, input_row))
    self.deps.layout_inline_menu(math.max(0, input_row - inline_menu_height), width, inline_menu_height)
  end

  local input_config = self.deps.input_window_config(input_row, math.max(1, width - 2), input_height)
  input_config.focusable = not permission_active
  vim.api.nvim_win_set_config(input_win, input_config)
  vim.api.nvim_win_set_config(status_win, {
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
  if self.deps.command_menu_visible() then
    self.deps.layout_command_menu()
  end
  self.deps.layout_widgets(width, input_row, input_height, above_widget_height, below_widget_height)

  local overlay_height = input_height + footer_height + 2 + widget_height + inline_menu_height
  local overlay_changed = self.overlay_height ~= overlay_height
  local transcript_height = math.max(0, height - overlay_height)
  local transcript_height_changed = self.transcript_height ~= transcript_height
  self.overlay_height = overlay_height
  self.transcript_height = transcript_height
  self.deps.render_status()
  if overlay_changed or transcript_width_changed or transcript_height_changed then
    self.deps.render_transcript()
  end
end

function Shell:close()
  self.deps.stop_activity_animation()
  self.deps.close_image_preview()
  self.deps.clear_transcript_images()
  self.deps.cancel_permissions()
  self.deps.close_command_menu()
  self.deps.close_inline_menu({ focus = false, layout = false })
  self.deps.close_widget_windows()
  self.deps.close_input_windows()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.permission_restore_height = nil
  self.transcript_height = nil
  self.win = nil
  self.deps.reset_transcript_width()
  self.deps.sync_welcome_animation()
end

function Shell:set_position(position)
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

function Shell:open(focus_input)
  self.deps.sync_image_backends()
  local buf = self.deps.ensure_transcript_buffer()
  local input_buf = self.deps.ensure_input_buffer()
  local status_buf = self.deps.ensure_status_buffer()
  if self:is_open() then
    if focus_input ~= false then
      self.deps.focus_input()
    end
    return
  end

  self:close()
  local chat_options = config.get().chat
  self.position = self.position or chat_options.position
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
      border = (chat_options.float or {}).border or "rounded",
      zindex = 40,
    })
  elseif self.position == "bottom" then
    vim.cmd("botright new")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(self.win, math.max(10, math.floor(vim.o.lines * chat_options.height)))
  elseif self.position == "right" then
    vim.cmd("botright vnew")
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(self.win, right_width(vim.o.columns, chat_options.width))
  else
    error("pi.nvim: chat.position must be 'right', 'bottom', 'tab', or 'float'")
  end
  vim.api.nvim_win_set_buf(self.win, buf)
  style_window(self.win, "PiCanvasNormal")
  vim.wo[self.win].cursorline = false
  vim.wo[self.win].winbar = ""

  local width = vim.api.nvim_win_get_width(self.win)
  local input_win = vim.api.nvim_open_win(input_buf, false, self.deps.input_window_config(0, math.max(1, width - 2), 3))
  style_window(input_win, "PiInputNormal")
  vim.wo[input_win].cursorline = false
  vim.wo[input_win].spell = false
  vim.wo[input_win].winblend = 0
  vim.wo[input_win].winbar = " "

  local status_win = vim.api.nvim_open_win(status_buf, false, {
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
  style_window(status_win, "PiStatusNormal")
  vim.wo[status_win].wrap = false
  vim.wo[status_win].winbar = ""
  self.deps.set_input_windows(input_win, status_win)

  self.deps.update_input_chrome()
  self.deps.sync_activity_animation()
  self.deps.sync_welcome_animation()
  if focus_input ~= false then
    self.deps.focus_input()
  end
end

M.Shell = Shell
return M
