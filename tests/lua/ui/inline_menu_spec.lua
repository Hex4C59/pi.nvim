local InlineMenu = require("pi.ui.inline_menu").InlineMenu
local limits = require("pi.ui.inline_menu").limits

require("pi.ui.highlights").setup()

local parent_buf
local parent_win
local menu

local function mapping(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function has_highlight(buf, name)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if details.hl_group == name or details.line_hl_group == name then
      return true
    end
  end
  return false
end

local function run()
  local root = vim.fs.joinpath(vim.fn.getcwd(), "inline-menu-project")
  parent_buf = vim.api.nvim_create_buf(false, true)
  parent_win = vim.api.nvim_open_win(parent_buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 60,
    height = 18,
    style = "minimal",
  })

  local layout_calls = 0
  local prompt_focuses = 0
  local editor_returns = 0
  menu = InlineMenu.new({
    root = root,
    namespace = vim.api.nvim_create_namespace("pi.nvim.inline-menu.spec"),
    name_buffer = function(buf, kind, project_root)
      vim.b[buf].pi_kind = kind
      vim.b[buf].pi_root = project_root
    end,
    main_window = function()
      return parent_win
    end,
    layout = function()
      layout_calls = layout_calls + 1
      if menu:active() then
        menu:layout(2, vim.api.nvim_win_get_width(parent_win), menu:desired_height())
      end
    end,
    focus_input = function()
      prompt_focuses = prompt_focuses + 1
      if vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
      end
    end,
    return_to_editor = function()
      editor_returns = editor_returns + 1
      if vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
      end
    end,
  })

  local selected
  local items = {
    { id = "alpha", label = "Alpha", description = "first choice" },
    { id = "jupiter", label = "Jupiter", description = "second choice" },
    { id = "kilo", label = "Kilo", description = "third choice" },
  }
  local surface = menu:open({
    kind = "select",
    title = "Fixture choices",
    items = items,
    current = items[2],
    on_select = function(item)
      selected = item
    end,
  })
  assert(menu:active() and menu:visible(), "select menu did not open")
  assert(vim.api.nvim_get_current_win() == menu:window(), "select menu did not take keyboard focus")
  assert(menu:owns_buffer(menu:buffer()), "InlineMenu does not own its nofile buffer")
  assert(vim.bo[menu:buffer()].buftype == "nofile" and not vim.bo[menu:buffer()].modifiable, "menu buffer changed")
  assert(
    vim.b[menu:buffer()].pi_kind == "inline-menu" and vim.b[menu:buffer()].pi_root == root,
    "menu buffer metadata changed"
  )
  local config = vim.api.nvim_win_get_config(menu:window())
  assert(config.relative == "win" and config.win == parent_win, "menu is not relative to the Chat canvas")
  assert(config.col == 0 and config.width == vim.api.nvim_win_get_width(parent_win), "menu is not full-width")
  assert(
    config.border == nil
      or config.border == ""
      or config.border == "none"
      or (type(config.border) == "table" and #config.border == 0),
    "menu gained a detached border"
  )
  assert(has_highlight(menu:buffer(), "PiInlineTitle"), "menu title lacks semantic highlighting")
  assert(has_highlight(menu:buffer(), "PiInlineSelected"), "selected row lacks a non-color-only marker surface")
  assert(buffer_text(menu:buffer()):find("* Jupiter", 1, true), "current authoritative value is not marked")

  local j = mapping(menu:buffer(), "j")
  local k = mapping(menu:buffer(), "k")
  assert(type(j.callback) == "function" and type(k.callback) == "function", "printable filter mappings are missing")
  j.callback()
  assert(menu:_frame().query == "j", "j navigated instead of filtering")
  assert(#menu:_frame().filtered == 1 and menu:_frame().filtered[1].value.id == "jupiter", "j filter was incorrect")
  k.callback()
  assert(menu:_frame().query == "jk" and #menu:_frame().filtered == 0, "k did not append to the filter")
  mapping(menu:buffer(), "<BS>").callback()
  mapping(menu:buffer(), "<BS>").callback()
  assert(menu:_frame().query == "" and #menu:_frame().filtered == 3, "Backspace did not restore candidates")
  local before_navigation = menu:_frame().current
  mapping(menu:buffer(), "<Down>").callback()
  assert(menu:_frame().current == (before_navigation % 3) + 1, "Down did not navigate candidates")
  mapping(menu:buffer(), "<Up>").callback()
  assert(menu:_frame().current == before_navigation, "Up did not navigate candidates")
  mapping(menu:buffer(), "<CR>").callback()
  assert(
    selected == items[before_navigation] and surface.closed and not menu:active(),
    "selection did not close before callback"
  )

  surface = menu:open({ kind = "select", title = "Empty", items = items, query = "no-match" })
  assert(
    #menu:_frame().filtered == 0 and buffer_text(menu:buffer()):find("No matches", 1, true),
    "empty filter state changed"
  )
  menu:close()

  local root_cancelled = 0
  local child_cancelled = 0
  local root_surface = menu:open({
    kind = "select",
    title = "Settings",
    items = { "Model" },
    keep_open = true,
    on_cancel = function()
      root_cancelled = root_cancelled + 1
    end,
  })
  local child_surface = root_surface:push({
    kind = "select",
    title = "Model",
    items = { "one", "two" },
    on_cancel = function()
      child_cancelled = child_cancelled + 1
    end,
  })
  assert(#menu.stack == 2 and buffer_text(menu:buffer()):find("Settings / Model", 1, true), "submenu stack is missing")
  mapping(menu:buffer(), "<Esc>").callback()
  assert(menu:active() and #menu.stack == 1, "submenu Escape closed the whole group")
  assert(
    child_surface.closed and not root_surface.closed and child_cancelled == 1,
    "submenu cancellation state changed"
  )
  mapping(menu:buffer(), "<Esc>").callback()
  assert(not menu:active() and root_surface.closed and root_cancelled == 1, "top-level Escape did not close the group")

  root_surface = menu:open({ kind = "select", title = "Return", items = { "one" } })
  root_surface:push({ kind = "select", title = "Nested", items = { "two" } })
  mapping(menu:buffer(), "<C-q>").callback()
  assert(not menu:active() and editor_returns == 1, "Ctrl-Q did not close the full group and return")

  local multi_result
  surface = menu:open({
    kind = "multi_select",
    title = "Scope",
    items = items,
    selected = { items[1] },
    on_select = function(result)
      multi_result = result
    end,
  })
  mapping(menu:buffer(), "<Tab>").callback()
  menu:move(1)
  mapping(menu:buffer(), "<Tab>").callback()
  menu:submit()
  assert(#multi_result == 1 and multi_result[1] == items[2] and surface.closed, "Tab multi-selection result changed")

  local confirmed
  menu:open({
    kind = "confirm",
    title = "Confirm fixture",
    message = "Apply the change?",
    on_confirm = function(value)
      confirmed = value
    end,
  })
  assert(menu:_frame().current == 1, "confirmation did not default to cancellation")
  menu:submit()
  assert(confirmed == false, "default confirmation submitted true")

  local input_value
  menu:open({
    kind = "input",
    title = "Input fixture",
    default = "ab",
    placeholder = "type here",
    on_submit = function(value)
      input_value = value
    end,
  })
  mapping(menu:buffer(), "j").callback()
  menu:submit()
  assert(input_value == "abj", "non-sensitive inline input lost printable text")

  surface = menu:open({ kind = "select", title = "Loading", items = {}, loading = true })
  assert(buffer_text(menu:buffer()):find("Loading", 1, true), "loading state is not visible")
  surface:set_error("fixture loading error")
  assert(buffer_text(menu:buffer()):find("fixture loading error", 1, true), "loading error did not replace progress")
  surface:close()

  local empty_submissions = 0
  surface = menu:open({
    kind = "multi_select",
    title = "Non-empty scope",
    items = { items[1] },
    on_empty = function()
      empty_submissions = empty_submissions + 1
    end,
  })
  menu:submit()
  assert(empty_submissions == 1 and menu:active(), "empty multi-selection did not remain open")
  surface:close()

  local more_cursor
  surface = menu:open({
    kind = "select",
    title = "Paged",
    items = { items[1] },
    next_cursor = "opaque-next",
    on_more = function(cursor, active)
      more_cursor = cursor
      active:append({ items[2] }, nil)
    end,
  })
  assert(buffer_text(menu:buffer()):find("1 of 1", 1, true), "pagination action was counted as a candidate")
  menu:move(1)
  menu:submit()
  assert(more_cursor == "opaque-next", "pagination changed the opaque cursor")
  assert(#menu:_frame().items == 2 and menu:_frame().next_cursor == nil, "pagination did not append and settle")
  surface:set_error("fixture page error")
  assert(buffer_text(menu:buffer()):find("fixture page error", 1, true), "error state is not visible")
  surface:close()

  local many = {}
  for index = 1, limits.items + 20 do
    table.insert(many, { id = tostring(index), label = string.rep("x", limits.line_chars + 20) })
  end
  surface = menu:open({
    kind = "select",
    title = "Bounded",
    items = many,
    query = string.rep("q", limits.query_chars + 20),
  })
  assert(#menu:_frame().items == limits.items and menu:_frame().truncated, "candidate retention limit changed")
  assert(vim.fn.strchars(menu:_frame().query) == limits.query_chars, "query limit changed")
  assert(vim.fn.strchars(menu:_frame().items[1].label) == limits.line_chars, "single-line limit changed")
  assert(menu:desired_height() <= limits.visible_height, "visible-height limit changed")

  surface:close()
  surface = menu:open({ kind = "select", title = "Depth 1", items = { "one" } })
  for depth = 2, limits.depth do
    surface = assert(surface:push({ kind = "select", title = "Depth " .. depth, items = { "one" } }))
  end
  assert(
    surface:push({ kind = "select", title = "Too deep", items = { "one" } }) == nil,
    "menu stack exceeded its depth limit"
  )
  assert(#menu.stack == limits.depth, "depth rejection mutated the active stack")
  surface:close()
  assert(not surface:set_error("stale"), "stale surface mutated a closed menu")
  surface:close()
  assert(surface.closed and not menu:active(), "surface cleanup is not idempotent")
  assert(layout_calls > 0, "menu changes did not request Chat layout")
  assert(
    vim.wait(300, function()
      return prompt_focuses > 0
    end, 5),
    "ordinary close did not restore prompt focus"
  )
end

local ok, err = xpcall(run, debug.traceback)
if menu then
  menu:destroy()
  menu:destroy()
end
if parent_win and vim.api.nvim_win_is_valid(parent_win) then
  vim.api.nvim_win_close(parent_win, true)
end
if parent_buf and vim.api.nvim_buf_is_valid(parent_buf) then
  vim.api.nvim_buf_delete(parent_buf, { force = true })
end
if not ok then
  error(err)
end

print("inline_menu_spec: ok")
