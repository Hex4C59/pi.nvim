local config = require("pi.config")
local InputArea = require("pi.ui.input").InputArea

config.setup({ chat = { max_input_height = 6 } })

local function styled_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

local function has_highlight(chunks, highlight)
  for _, chunk in ipairs(chunks or {}) do
    if chunk[2] == highlight then
      return true
    end
  end
  return false
end

local function mapping(buf, mode, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
end

local function has_extmark_highlight(buf, highlight)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local details = extmark[4] or {}
    if details.hl_group == highlight or details.line_hl_group == highlight then
      return true
    end
  end
  return false
end

local group
local parent_buf
local parent_win
local input
local input_buf
local status_buf
local input_win
local status_win
local original_notify = vim.notify
local original_mouse = vim.o.mouse
local original_mousemodel = vim.o.mousemodel
local original_clipboard = vim.o.clipboard

local function run()
  group = vim.api.nvim_create_augroup("PiNvimInputSpec", { clear = true })
  local root = vim.fs.joinpath(vim.fn.getcwd(), "input-project")
  parent_buf = vim.api.nvim_create_buf(false, true)
  parent_win = vim.api.nvim_open_win(parent_buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 72,
    height = 18,
    style = "minimal",
  })

  local calls = {
    layout = 0,
    close_command_menu = 0,
    select_command = {},
    abort = 0,
    select_model = 0,
    cycle_model = 0,
    cycle_permission_mode = 0,
    cycle_thinking_level = 0,
    left_mouse = 0,
    attachments = {},
    return_to_editor = 0,
    prefilled = {},
    submissions = {},
  }
  local flags = {
    command_menu_visible = false,
    accept_completion = false,
    update_command_menu = false,
    select_command = true,
  }
  local state = {
    active = false,
    activity = "idle",
    activity_text = "Thinking",
    animation_frame = 0,
    stats = { contextUsage = { percent = 42 } },
    queue = { steering = {}, followUp = {} },
    permission_mode = nil,
    permission_mode_label = "--",
    model = "fixture-model",
    thinking = "high",
    pending_image_count = 0,
  }
  local actions = {
    layout = function()
      calls.layout = calls.layout + 1
    end,
    close_command_menu = function()
      calls.close_command_menu = calls.close_command_menu + 1
      flags.command_menu_visible = false
    end,
    update_command_menu = function()
      return flags.update_command_menu
    end,
    command_menu_visible = function()
      return flags.command_menu_visible
    end,
    select_command = function(direction)
      table.insert(calls.select_command, direction)
      return flags.select_command
    end,
    accept_command_completion = function()
      return flags.accept_completion
    end,
    take_image_attachments = function()
      return { { type = "image", mimeType = "image/png", path = "/tmp/attachment.png" } }
    end,
    add_image_attachment = function(image)
      table.insert(calls.attachments, image)
      return true
    end,
    submit = function(prompt, behavior, images)
      table.insert(calls.submissions, {
        prompt = prompt,
        root = root,
        behavior = behavior,
        images = images,
      })
    end,
    abort = function()
      calls.abort = calls.abort + 1
    end,
    select_model = function()
      calls.select_model = calls.select_model + 1
    end,
    cycle_model = function()
      calls.cycle_model = calls.cycle_model + 1
    end,
    cycle_permission_mode = function()
      calls.cycle_permission_mode = calls.cycle_permission_mode + 1
    end,
    cycle_thinking_level = function()
      calls.cycle_thinking_level = calls.cycle_thinking_level + 1
    end,
    prefill_command = function(command)
      table.insert(calls.prefilled, command)
    end,
    return_to_editor = function()
      calls.return_to_editor = calls.return_to_editor + 1
      vim.api.nvim_set_current_win(parent_win)
      vim.cmd("stopinsert")
    end,
    toggle_tools = function() end,
    toggle_thinking = function() end,
    left_mouse = function()
      calls.left_mouse = calls.left_mouse + 1
      return true
    end,
  }
  input = InputArea.new({
    root = root,
    namespace = vim.api.nvim_create_namespace("pi.nvim.input.spec"),
    ui_group = group,
    state = function()
      return state
    end,
    main_window = function()
      return parent_win
    end,
    actions = actions,
    clipboard = {
      read_image = function()
        return flags.clipboard_image, flags.clipboard_image_error
      end,
      read_text = function()
        return flags.clipboard_text
      end,
    },
  })

  assert(not input:owns_buffer(nil), "InputArea claimed a buffer before construction")
  local initial_input_buf = input:ensure_input_buffer()
  local initial_status_buf = input:ensure_status_buffer()
  assert(input:ensure_input_buffer() == initial_input_buf, "input buffer creation is not idempotent")
  assert(input:ensure_status_buffer() == initial_status_buf, "status buffer creation is not idempotent")
  assert(
    input:owns_buffer(initial_input_buf) and input:owns_buffer(initial_status_buf),
    "InputArea did not own its buffers"
  )

  assert(vim.bo[initial_input_buf].filetype == "pi_prompt", "prompt filetype is not isolated")
  assert(vim.bo[initial_input_buf].modifiable, "prompt buffer must remain editable")
  assert(vim.api.nvim_buf_get_lines(initial_input_buf, 0, -1, false)[1] == "", "prompt contains placeholder text")
  assert(vim.b[initial_input_buf].completion == false, "external completion marker is not disabled")
  for _, option in ipairs({ "complete", "completefunc", "omnifunc", "tagfunc", "dictionary", "thesaurus" }) do
    assert(vim.bo[initial_input_buf][option] == "", "prompt completion option is not empty: " .. option)
  end
  assert(vim.bo[initial_input_buf].buftype == "nofile", "prompt buffer is not nofile")
  assert(vim.bo[initial_input_buf].bufhidden == "hide", "prompt buffer is not reusable across window closes")
  assert(not vim.bo[initial_input_buf].swapfile, "prompt buffer unexpectedly uses a swapfile")
  assert(
    vim.b[initial_input_buf].pi_kind == "prompt" and vim.b[initial_input_buf].pi_root == root,
    "prompt metadata changed"
  )
  assert(vim.bo[initial_status_buf].filetype == "pi_status", "status filetype changed")
  assert(not vim.bo[initial_status_buf].modifiable, "status buffer must be presentation-only")
  assert(
    vim.b[initial_status_buf].pi_kind == "status" and vim.b[initial_status_buf].pi_root == root,
    "status metadata changed"
  )

  vim.api.nvim_buf_delete(initial_input_buf, { force = true })
  vim.api.nvim_buf_delete(initial_status_buf, { force = true })
  input_buf = input:ensure_input_buffer()
  status_buf = input:ensure_status_buffer()
  assert(
    input_buf ~= initial_input_buf and vim.api.nvim_buf_is_valid(input_buf),
    "invalid input buffer was not recreated"
  )
  assert(
    status_buf ~= initial_status_buf and vim.api.nvim_buf_is_valid(status_buf),
    "invalid status buffer was not recreated"
  )
  assert(not input:owns_buffer(initial_input_buf), "InputArea retained ownership of its replaced buffer")

  for _, case in ipairs({
    { mode = "i", lhs = "<CR>" },
    { mode = "i", lhs = "<Down>" },
    { mode = "i", lhs = "<Up>" },
    { mode = "i", lhs = "<Esc>" },
    { mode = "i", lhs = "<M-p>" },
    { mode = "i", lhs = "<C-c>" },
    { mode = "i", lhs = "<C-l>" },
    { mode = "n", lhs = "<C-q>" },
    { mode = "i", lhs = "<C-q>" },
    { mode = "v", lhs = "<C-q>" },
    { mode = "n", lhs = "<C-p>" },
    { mode = "n", lhs = "<S-Tab>" },
    { mode = "i", lhs = "<LeftMouse>" },
    { mode = "i", lhs = "<RightMouse>" },
  }) do
    local map = mapping(input_buf, case.mode, case.lhs)
    assert(type(map.callback) == "function", "prompt mapping is missing: " .. case.lhs)
    assert(map.buffer == 1, "prompt mapping is not buffer-local: " .. case.lhs)
  end
  assert(mapping(input_buf, "i", "<CR>").expr == 0, "Insert Enter must not run under expression-map textlock")
  assert(mapping(input_buf, "i", "<Down>").expr == 0, "command navigation must redraw outside expression-map textlock")
  assert(mapping(input_buf, "n", "q").lhs == nil, "prompt retained a Normal-mode close shortcut")
  assert(mapping(input_buf, "n", "<C-x>").lhs == nil, "prompt retained Normal-mode Ctrl-X copy")
  assert(mapping(input_buf, "i", "<C-x>").lhs == nil, "prompt retained Insert-mode Ctrl-X copy")

  mapping(input_buf, "i", "<Down>").callback()
  mapping(input_buf, "i", "<Up>").callback()
  assert(vim.deep_equal(calls.select_command, { 1, -1 }), "command menu navigation did not delegate")
  mapping(input_buf, "i", "<M-p>").callback()
  mapping(input_buf, "i", "<C-c>").callback()
  mapping(input_buf, "i", "<C-l>").callback()
  mapping(input_buf, "n", "<C-p>").callback()
  mapping(input_buf, "n", "<S-Tab>").callback()
  mapping(input_buf, "i", "<LeftMouse>").callback()
  assert(state.permission_mode == nil, "permission shortcut changed local authority")
  assert(calls.abort == 1, "abort shortcut did not delegate")
  assert(
    vim.deep_equal(calls.prefilled, { "/permissions ", "/model ", "/model ", "/thinking " }),
    "selection shortcuts did not prefill their slash commands"
  )
  assert(
    calls.select_model == 0
      and calls.cycle_model == 0
      and calls.cycle_permission_mode == 0
      and calls.cycle_thinking_level == 0,
    "selection shortcuts bypassed the shared inline command entry points"
  )
  assert(calls.left_mouse == 1, "prompt mouse mapping did not delegate to the transcript action")

  flags.command_menu_visible = true
  mapping(input_buf, "i", "<Esc>").callback()
  assert(calls.close_command_menu >= 1 and calls.abort == 1, "Escape did not close the command menu first")
  state.activity = "working"
  mapping(input_buf, "i", "<Esc>").callback()
  assert(calls.abort == 2, "Escape did not abort active work after the menu closed")
  state.activity = "idle"

  local parent_width = vim.api.nvim_win_get_width(parent_win)
  local input_config = input:window_config(10, parent_width - 2, 3)
  assert(input_config.relative == "win" and input_config.win == parent_win, "prompt config lost its parent window")
  assert(input_config.col == 0 and input_config.width + 2 == parent_width, "prompt config is not canvas-aligned")
  assert(input_config.border[1][1] == "┌" and input_config.border[3][1] == "┐", "prompt top corners are not square")
  assert(
    input_config.border[5][1] == "┘" and input_config.border[7][1] == "└",
    "prompt bottom corners are not square"
  )
  assert(input_config.border[2][1] == "─" and input_config.border[6][1] == "─", "prompt horizontal edges changed")
  assert(input_config.border[4][1] == "│" and input_config.border[8][1] == "│", "prompt vertical edges changed")
  for index, segment in ipairs(input_config.border) do
    assert(segment[2] == (index % 2 == 1 and "PiInputCorner" or "PiInputBorder"), "prompt border semantics changed")
  end
  assert(vim.api.nvim_strwidth(styled_text(input_config.title)) == input_config.width, "prompt top frame width changed")
  assert(
    vim.api.nvim_strwidth(styled_text(input_config.footer)) == input_config.width,
    "prompt bottom frame width changed"
  )

  input_win = vim.api.nvim_open_win(input_buf, false, input_config)
  status_win = vim.api.nvim_open_win(status_buf, false, {
    relative = "win",
    win = parent_win,
    row = 15,
    col = 0,
    width = parent_width,
    height = 1,
    style = "minimal",
    focusable = false,
  })
  input:set_windows(input_win, status_win)
  input:update_chrome()
  assert(vim.wo[input_win].winbar == " ", "prompt top padding row is missing")
  assert(vim.wo[input_win].winhighlight:find("Normal:PiInputNormal", 1, true), "prompt surface highlight is missing")
  assert(
    vim.wo[input_win].winhighlight:find("Cursor:PiInputCursor", 1, true)
      and vim.wo[input_win].winhighlight:find("CursorIM:PiInputCursor", 1, true)
      and vim.wo[input_win].winhighlight:find("lCursor:PiInputCursor", 1, true),
    "prompt cursor/IME highlight contract changed"
  )
  local actual_status_config = vim.api.nvim_win_get_config(status_win)
  assert(actual_status_config.relative == "win" and actual_status_config.win == parent_win, "status lost its parent")
  assert(actual_status_config.focusable == false and actual_status_config.height == 1, "status window can steal focus")

  local idle_top, idle_bottom = input:frame(32)
  assert(vim.api.nvim_strwidth(styled_text(idle_top)) == 32, "idle top frame width changed")
  assert(vim.api.nvim_strwidth(styled_text(idle_bottom)) == 32, "idle bottom frame width changed")
  assert(not styled_text(idle_bottom):find("Idle", 1, true), "idle label should remain hidden")

  state.active = true
  state.activity = "working"
  state.activity_text = "Thinking"
  state.animation_frame = 0
  local working_top, working_bottom = input:frame(32)
  local first_working = vim.inspect(working_top)
  assert(has_highlight(working_top, "PiInputBorderPulse"), "working frame is missing its moving highlight")
  assert(styled_text(working_bottom):find("Thinking", 1, true), "working label is missing from the bottom frame")
  assert(not styled_text(working_top):find("Thinking", 1, true), "working label leaked into the top frame")
  state.animation_frame = 2
  local moved_top, moved_bottom = input:frame(32)
  assert(vim.inspect(moved_top) ~= first_working, "working frame highlight did not move")
  assert(vim.api.nvim_strwidth(styled_text(moved_top)) == 32, "animated top frame width changed")
  assert(vim.api.nvim_strwidth(styled_text(moved_bottom)) == 32, "animated bottom frame width changed")

  state.activity_text = "Assessing cohesion"
  local _, reasoning_bottom = input:frame(32)
  assert(
    styled_text(reasoning_bottom):find("Assessing cohesion", 1, true),
    "complete reasoning stage did not replace Thinking"
  )
  state.incomplete_reasoning_header = "**next"
  local _, incomplete_bottom = input:frame(32)
  assert(
    styled_text(incomplete_bottom):find("Assessing cohesion", 1, true),
    "incomplete next stage replaced the current label"
  )
  state.activity_text = "Thinking"
  local _, public_bottom = input:frame(32)
  assert(
    not styled_text(public_bottom):find("Assessing cohesion", 1, true),
    "public output did not clear the reasoning label"
  )

  state.active = false
  state.activity = "error"
  local error_top, error_bottom, error_edge, error_corner = input:frame(32)
  assert(styled_text(error_bottom):find("Error", 1, true), "error frame label is missing")
  assert(error_edge == "PiInputBorderError" and error_corner == "PiInputCornerError", "error frame semantics changed")
  assert(has_highlight(error_top, "PiInputBorderError"), "error frame edge highlight is missing")
  local narrow_top, narrow_bottom = input:frame(8)
  assert(vim.api.nvim_strwidth(styled_text(narrow_top)) == 8, "narrow top frame overflowed")
  assert(vim.api.nvim_strwidth(styled_text(narrow_bottom)) == 8, "narrow bottom frame overflowed")

  state.activity = "idle"
  state.permission_mode = nil
  state.permission_mode_label = "--"
  state.queue = { steering = {}, followUp = {} }
  state.stats = { contextUsage = { percent = 42 }, cost = 12.34, cacheRead = 999 }
  local unsynced = input:status_text(80)
  assert(#unsynced == 1 and unsynced[1]:find("--", 1, true), "unsynchronized permission mode is not visible")
  assert(unsynced[1]:find("fixture-model · high", 1, true), "wide status lost model/thinking state")
  assert(unsynced[1]:find("context 42%", 1, true), "status context percentage changed")
  assert(
    not unsynced[1]:find("cost", 1, true) and not unsynced[1]:find("cache", 1, true),
    "persistent status leaked cost/cache detail"
  )
  assert(vim.api.nvim_strwidth(unsynced[1]) <= 80 and not unsynced[1]:find("[\r\n]"), "status is not one bounded line")

  for _, permission in ipairs({
    { mode = "manual", label = "Manual", group = "PiStatusPermissionManual" },
    { mode = "acceptEdits", label = "Accept edits", group = "PiStatusPermissionAcceptEdits" },
    { mode = "auto", label = "Auto", group = "PiStatusPermissionAuto" },
    { mode = "plan", label = "Plan", group = "PiStatusPermissionPlan" },
  }) do
    state.permission_mode = permission.mode
    state.permission_mode_label = permission.label
    input:render_status()
    local status_line = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)[1]
    assert(status_line:find(permission.label, 1, true), "permission label is missing: " .. permission.mode)
    assert(
      has_extmark_highlight(status_buf, permission.group),
      "permission semantic highlight is missing: " .. permission.mode
    )
  end

  local narrow_status = input:status_text(40)
  assert(narrow_status[1]:find("Plan", 1, true), "narrow status did not prioritize permission mode")
  assert(not narrow_status[1]:find("fixture-model", 1, true), "narrow status retained lower-priority model detail")
  state.queue = { steering = { "one", "two" }, followUp = { "three" } }
  local queued_status = input:status_text(80)
  assert(queued_status[1]:find("steer 2", 1, true), "steering queue count is missing")
  assert(queued_status[1]:find("next 1", 1, true), "follow-up queue count is missing")
  assert(not queued_status[1]:find("context", 1, true), "queue status did not take priority over context")

  state.pending_image_count = 2
  input:render_attachments()
  local attachment_found = false
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(input_buf, -1, 0, -1, { details = true })) do
    local virt_text = (extmark[4] or {}).virt_text
    if virt_text and vim.inspect(virt_text):find("2 images attached", 1, true) then
      attachment_found = true
    end
  end
  assert(attachment_found, "validated attachment count is missing from the prompt")
  state.pending_image_count = 0

  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  assert(input:desired_input_height() == 3, "empty prompt lost its minimum padded height")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "first", "second" })
  assert(input:desired_input_height() == 4, "multiline prompt did not grow with padding")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { string.rep("x", 150) })
  assert(input:desired_input_height() == 5, "long wrapped prompt did not use display width")
  local layout_before_resize = calls.layout
  input:resize()
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { string.rep("x", 280) })
  input:resize()
  assert(calls.layout == layout_before_resize + 2, "same-line wrapping changes were incorrectly deduplicated")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "1", "2", "3", "4", "5", "6", "7" })
  assert(input:desired_input_height() == 6, "prompt height exceeded its configured maximum")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  input:resize()
  assert(input:desired_input_height() == 3, "cleared prompt did not shrink")

  input:set_input("first\nsecond")
  assert(calls.close_command_menu >= 2, "set_input did not reset command-menu state")
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { "first", "second" }),
    "set_input lost content"
  )
  local cursor = vim.api.nvim_win_get_cursor(input_win)
  assert(cursor[1] == 2 and cursor[2] == #"second", "set_input did not place the cursor at the prompt end")
  local start_insert_windows = {}
  input._start_insert = function()
    table.insert(start_insert_windows, vim.api.nvim_get_current_win())
  end
  input:focus()
  assert(vim.api.nvim_get_current_win() == input_win, "focus did not select the prompt window")
  assert(vim.deep_equal(start_insert_windows, { input_win }), "focus did not request Insert mode for the prompt window")

  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "alpha", "beta" })
  flags.clipboard_text = "XX\nYY"
  assert(input:paste_at_mouse({ winid = input_win, line = 1, column = 3 }), "right-click text paste was not handled")
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { "alXX", "YYpha", "beta" }),
    "right-click text paste ignored the clicked byte position"
  )
  assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(input_win), { 2, 2 }),
    "right-click text paste did not leave the cursor after inserted text"
  )

  flags.clipboard_text = nil
  flags.clipboard_image = { type = "image", mimeType = "image/png", data = "fixture" }
  local before_image_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
  assert(input:paste_at_mouse({ winid = input_win, line = 3, column = 2 }), "right-click image paste was not handled")
  assert(#calls.attachments == 1 and calls.attachments[1] == flags.clipboard_image, "clipboard image was not attached")
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), before_image_lines),
    "image paste changed prompt text"
  )

  local clipboard_notifications = {}
  vim.notify = function(message, level, options)
    table.insert(clipboard_notifications, { message = message, level = level, options = options })
  end
  flags.clipboard_image = nil
  flags.clipboard_image_error = "image clipboard unavailable"
  flags.clipboard_text = "fallback"
  assert(
    input:paste_at_mouse({ winid = input_win, line = 3, column = 1 }),
    "clipboard image failure did not recover with text"
  )
  assert(
    vim.api.nvim_buf_get_lines(input_buf, 2, 3, false)[1] == "fallbackbeta",
    "clipboard failure fallback inserted text at the wrong position"
  )
  assert(
    #clipboard_notifications == 1 and clipboard_notifications[1].message:find("image clipboard unavailable", 1, true),
    "clipboard image failure was not reported"
  )
  vim.notify = original_notify
  flags.clipboard_image_error = nil
  flags.clipboard_text = nil
  assert(
    vim.o.mouse == original_mouse and vim.o.mousemodel == original_mousemodel and vim.o.clipboard == original_clipboard,
    "prompt mouse paste changed a global mouse or clipboard option"
  )
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "first", "second" })
  vim.api.nvim_win_set_cursor(input_win, { 2, #"second" })
  start_insert_windows = { input_win }

  local abort_before_idle_escape = calls.abort
  mapping(input_buf, "i", "<Esc>").callback()
  assert(calls.abort == abort_before_idle_escape, "idle Escape interrupted work")
  assert(#start_insert_windows == 1, "idle Escape scheduled an unnecessary mode transition")

  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = input_buf })
  assert(
    vim.wait(300, function()
      return #start_insert_windows == 2
    end, 5),
    "InsertLeave guard did not request Insert mode"
  )
  assert(start_insert_windows[2] == input_win, "InsertLeave guard targeted the wrong window")

  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = input_buf })
  vim.api.nvim_set_current_win(parent_win)
  local guard_drained = false
  vim.schedule(function()
    guard_drained = true
  end)
  assert(
    vim.wait(300, function()
      return guard_drained
    end, 5),
    "InsertLeave guard did not drain"
  )
  assert(#start_insert_windows == 2, "InsertLeave guard ran after leaving the prompt")
  assert(vim.api.nvim_get_current_win() == parent_win, "InsertLeave guard stole focus after leaving the prompt")
  assert(vim.api.nvim_get_mode().mode:sub(1, 1) == "n", "leaving the prompt did not preserve Normal mode")

  vim.api.nvim_set_current_win(input_win)
  assert(
    vim.wait(300, function()
      return #start_insert_windows == 3
    end, 5),
    "re-entering the prompt did not request Insert mode"
  )
  assert(start_insert_windows[3] == input_win, "WinEnter guard targeted the wrong window")
  mapping(input_buf, "i", "<C-q>").callback()
  assert(calls.return_to_editor == 1, "Ctrl-Q did not delegate prompt exit")
  assert(vim.api.nvim_get_current_win() == parent_win, "Ctrl-Q did not leave the prompt window")
  assert(vim.api.nvim_get_mode().mode:sub(1, 1) == "n", "Ctrl-Q did not return in Normal mode")
  input:focus()
  assert(#start_insert_windows == 4, "prompt focus did not request Insert mode after Ctrl-Q")

  flags.accept_completion = false
  state.pending_image_count = 0
  mapping(input_buf, "i", "<CR>").callback()
  assert(#calls.submissions == 1, "Insert Enter did not submit the prompt")
  assert(calls.submissions[1].prompt == "first\nsecond", "submission lost embedded newlines")
  assert(calls.submissions[1].root == root, "submission lost its project binding")
  assert(calls.submissions[1].behavior == nil, "normal Enter changed queue behavior")
  assert(#calls.submissions[1].images == 1, "submission did not forward validated attachments")
  assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "", "accepted local submission did not clear prompt")

  input:set_input("follow-up")
  mapping(input_buf, "i", "<M-CR>").callback()
  assert(calls.submissions[2].behavior == "followUp", "Meta-Enter did not request follow-up delivery")
  local submissions_before_empty = #calls.submissions
  input:set_input("")
  mapping(input_buf, "i", "<CR>").callback()
  assert(#calls.submissions == submissions_before_empty, "empty prompt submitted without an attachment")
  flags.accept_completion = true
  input:set_input("/command")
  mapping(input_buf, "i", "<CR>").callback()
  assert(#calls.submissions == submissions_before_empty, "accepted command completion also submitted the prompt")
  assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "/command", "command completion cleared prompt text")
  flags.accept_completion = false

  local reusable_input = input_buf
  local reusable_status = status_buf
  vim.api.nvim_win_close(status_win, true)
  input:close_windows()
  assert(not vim.api.nvim_win_is_valid(input_win), "close_windows left the prompt window open")
  assert(
    vim.api.nvim_buf_is_valid(reusable_input) and vim.api.nvim_buf_is_valid(reusable_status),
    "close_windows deleted reusable buffers"
  )
  assert(input:window() == nil and input:status_window() == nil, "close_windows retained invalid handles")

  vim.api.nvim_buf_delete(reusable_status, { force = true })
  input:destroy()
  input:destroy()
  assert(not vim.api.nvim_buf_is_valid(reusable_input), "InputArea input buffer survived destroy")
  assert(
    not input:owns_buffer(reusable_input) and input:buffer() == nil and input:status_buffer() == nil,
    "destroy retained owned resources"
  )
end

local ok, err = xpcall(run, debug.traceback)
vim.notify = original_notify
if input then
  pcall(input.destroy, input)
end
local function close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end
local function delete_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
close_window(status_win)
close_window(input_win)
close_window(parent_win)
delete_buffer(status_buf)
delete_buffer(input_buf)
delete_buffer(parent_buf)
if group then
  pcall(vim.api.nvim_del_augroup_by_id, group)
end
if not ok then
  error(err)
end

print("input_spec: ok")
