local command_menu = require("pi.ui.command_menu")
local CommandMenu = command_menu.CommandMenu
local truncate_display = require("pi.ui.input").truncate_display

require("pi.ui.highlights").setup()

local source_commands = {
  { name = "model", description = "Dynamic duplicate", source = "extension" },
  { name = "zzfixture", description = "Injected extension command", source = "extension" },
  { name = "prompt-work", description = "Injected prompt template", source = "prompt" },
  { name = "skill-work", description = "Injected skill", source = "skill" },
}
local authoritative_source = vim.deepcopy(source_commands)

local merged = command_menu.commands(source_commands)
assert(merged[1].name == "settings", "stable builtin catalogue order changed")
assert(merged[#merged - 2].name == "zzfixture", "dynamic extension command order changed")
assert(merged[#merged - 1].name == "prompt-work", "dynamic prompt command order changed")
assert(merged[#merged].name == "skill-work", "dynamic skill command order changed")
local model_count = 0
for _, command in ipairs(merged) do
  if command.name == "model" then
    model_count = model_count + 1
  end
end
assert(model_count == 1, "dynamic command did not deduplicate against the builtin catalogue")
assert(vim.deep_equal(source_commands, authoritative_source), "catalogue completion mutated its source list")

local all_matches = command_menu.complete(source_commands, 0, "/")
local matches_by_word = {}
for _, match in ipairs(all_matches) do
  matches_by_word[match.word] = match
end
assert(matches_by_word["/model"].kind == "PI", "native command kind changed")
assert(matches_by_word["/scoped-models"].kind == "TUI", "RPC-limited command kind changed")
assert(matches_by_word["/zzfixture"].kind == "EXT", "Extension command kind changed")
assert(matches_by_word["/prompt-work"].kind == "PROMPT", "prompt-template command kind changed")
assert(matches_by_word["/skill-work"].kind == "SKILL", "skill command kind changed")
assert(matches_by_word["/zzfixture"].menu == "Injected extension command", "command description metadata changed")

local prefix_matches = command_menu.complete(source_commands, 0, "/zzf")
assert(prefix_matches[1].word == "/zzfixture", "exact prefix completion changed")
local case_matches = command_menu.complete(source_commands, 0, "/ZZF")
assert(case_matches[1].word == "/zzfixture", "completion is no longer case-insensitive")
local fuzzy_matches = command_menu.complete(source_commands, 0, "/smd")
assert(#fuzzy_matches == 1 and fuzzy_matches[1].word == "/scoped-models", "fuzzy subsequence match changed")
assert(vim.deep_equal(fuzzy_matches[1].match_positions, { 0, 7, 9 }), "fuzzy highlight positions changed")
assert(#command_menu.complete(source_commands, 0, "/no-such-command") == 0, "no-match query returned commands")
assert(matches_by_word["/model"].abbr:find("<provider/model>", 1, true), "command argument hint is missing")

local root = vim.fs.joinpath(vim.fn.getcwd(), "command-menu-project")
local parent_buf = vim.api.nvim_create_buf(false, true)
local parent_win = vim.api.nvim_open_win(parent_buf, false, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 60,
  height = 18,
  style = "minimal",
})
local input_buf = vim.api.nvim_create_buf(false, true)
local input_win = vim.api.nvim_open_win(input_buf, true, {
  relative = "win",
  win = parent_win,
  row = 12,
  col = 0,
  width = 58,
  height = 1,
  style = "minimal",
})
vim.wo[input_win].virtualedit = "onemore"
local parent_ref = parent_win
local input_ref = input_win
local menu = CommandMenu.new({
  root = root,
  namespace = vim.api.nvim_create_namespace("pi.nvim.command-menu.spec"),
  name_buffer = function(buf, kind, project_root)
    vim.b[buf].pi_kind = kind
    vim.b[buf].pi_root = project_root
  end,
  truncate_display = truncate_display,
  commands = function()
    return source_commands
  end,
  main_window = function()
    return parent_ref
  end,
  input_buffer = function()
    return input_buf
  end,
  input_window = function()
    return input_ref
  end,
})

local function set_input(value)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { value })
  vim.api.nvim_win_set_cursor(input_win, { 1, #value })
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

assert(menu:buffer() == nil and menu:window() == nil, "CommandMenu eagerly created resources")
assert(not menu:owns_buffer(nil), "CommandMenu claimed a buffer before creation")

set_input("/mod")
assert(command_menu.complete(source_commands, 1, "") == 0, "module completion start column changed")
set_input("  /mod")
assert(command_menu.complete(source_commands, 1, "") == 2, "indented slash completion start column changed")
set_input("ordinary prompt")
assert(command_menu.complete(source_commands, 1, "") == -3, "ordinary prompt unexpectedly starts completion")
set_input("prefix /mod")
assert(command_menu.complete(source_commands, 1, "") == -3, "slash after prompt text unexpectedly starts completion")

set_input("/zzf")
assert(menu:update(), "valid slash context did not open CommandMenu")
assert(menu:visible(), "CommandMenu window was not created")
assert(menu.matches[1].word == "/zzfixture", "instance completion ignored its injected catalogue")
assert(menu:selected_index() == 1, "initial command selection changed")
local menu_buf = assert(menu:buffer(), "CommandMenu buffer is missing")
local menu_win = assert(menu:window(), "CommandMenu window is missing")
assert(menu:owns_buffer(menu_buf), "CommandMenu does not own its buffer")
assert(
  vim.bo[menu_buf].buftype == "nofile" and vim.bo[menu_buf].bufhidden == "hide",
  "menu buffer is not reusable nofile"
)
assert(not vim.bo[menu_buf].swapfile and not vim.bo[menu_buf].modifiable, "menu buffer mutability contract changed")
assert(vim.bo[menu_buf].filetype == "pi_commands", "menu filetype changed")
assert(vim.b[menu_buf].pi_kind == "commands" and vim.b[menu_buf].pi_root == root, "menu buffer metadata changed")

local menu_config = vim.api.nvim_win_get_config(menu_win)
assert(menu_config.relative == "win" and menu_config.win == parent_win, "menu lost its canvas parent")
assert(
  menu_config.col == 0 and menu_config.width == vim.api.nvim_win_get_width(parent_win),
  "menu is not canvas-aligned"
)
assert(menu_config.row + menu_config.height <= vim.api.nvim_win_get_config(input_win).row, "menu is not above prompt")
assert(menu_config.focusable == false, "menu can steal prompt focus")
assert(
  menu_config.border == nil
    or menu_config.border == ""
    or menu_config.border == "none"
    or (type(menu_config.border) == "table" and #menu_config.border == 0),
  "menu rendered a detached decorative border"
)
assert(vim.api.nvim_get_current_win() == input_win, "menu opening moved focus out of the prompt")
assert(vim.wo[menu_win].winhighlight:find("Normal:PiCommandMenu", 1, true), "menu surface highlight is missing")
local menu_surface = vim.api.nvim_get_hl(0, { name = "PiCommandMenu", link = false })
local canvas_surface = vim.api.nvim_get_hl(0, { name = "PiCanvasNormal", link = false })
local selected_surface = vim.api.nvim_get_hl(0, { name = "PiCommandSelected", link = false })
assert(menu_surface.bg == canvas_surface.bg, "menu surface does not blend into the canvas")
assert(selected_surface.bg ~= canvas_surface.bg, "selected command row lacks a distinct local surface")
local rendered_lines = vim.api.nvim_buf_get_lines(menu_buf, 0, -1, false)
assert(rendered_lines[1]:find("› /zzfixture", 1, true), "selected command marker is missing")
for _, line in ipairs(rendered_lines) do
  assert(vim.api.nvim_strwidth(line) <= menu_config.width, "wide menu row overflowed")
end
assert(has_extmark_highlight(menu_buf, "PiCommandMatch"), "matched command characters are not highlighted")
assert(has_extmark_highlight(menu_buf, "PiCommandSelected"), "selected command row is not highlighted")
assert(vim.fn.pumvisible() == 0, "native popup menu leaked into CommandMenu")

menu:close()
set_input("/")
assert(menu:update(), "full catalogue did not open")
local match_count = #menu.matches
assert(menu:select(-1), "backward command selection failed")
assert(menu:selected_index() == match_count, "backward selection did not wrap")
assert(menu:select(1) and menu:selected_index() == 1, "forward selection did not wrap")
assert(menu:select(1) and menu:selected_index() == 2, "forward command selection failed")

set_input("/c")
assert(menu:update(), "multi-match command query did not open")
local compact_index
for index, match in ipairs(menu.matches) do
  if match.word == "/compact" then
    compact_index = index
    break
  end
end
assert(compact_index, "compact command is missing from /c matches")
menu.selected = compact_index
menu:layout()
set_input("/co")
assert(menu:update(), "refined command query did not update")
assert(menu.matches[menu:selected_index()].word == "/compact", "selection was not retained across compatible updates")

vim.api.nvim_win_set_config(parent_win, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 24,
  height = 18,
})
vim.api.nvim_win_set_config(input_win, {
  relative = "win",
  win = parent_win,
  row = 12,
  col = 0,
  width = 22,
  height = 1,
})
assert(menu:layout(), "narrow menu layout failed")
local narrow_config = vim.api.nvim_win_get_config(menu:window())
for _, line in ipairs(vim.api.nvim_buf_get_lines(menu_buf, 0, -1, false)) do
  assert(vim.api.nvim_strwidth(line) <= narrow_config.width, "narrow menu row overflowed")
end

vim.api.nvim_win_set_config(input_win, {
  relative = "win",
  win = parent_win,
  row = 0,
  col = 0,
  width = 22,
  height = 1,
})
assert(not menu:layout() and not menu:visible(), "zero-height menu created an invalid window")
assert(vim.api.nvim_buf_is_valid(menu_buf), "closing zero-height menu deleted its reusable buffer")

vim.api.nvim_win_set_config(parent_win, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 60,
  height = 18,
})
vim.api.nvim_win_set_config(input_win, {
  relative = "win",
  win = parent_win,
  row = 12,
  col = 0,
  width = 58,
  height = 1,
})
set_input("  /zzf")
assert(menu:update(), "indented slash context did not reopen the menu")
assert(menu:buffer() == menu_buf, "repeated open did not reuse the menu buffer")
assert(menu:accept(), "selected completion was not accepted")
local accepted_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1]
assert(accepted_line == "  /zzfixture ", "accepted completion did not replace its slash context")
assert(vim.api.nvim_win_get_cursor(input_win)[2] == #accepted_line, "accepted completion cursor placement changed")
assert(
  not menu:visible() and vim.api.nvim_get_current_win() == input_win,
  "acceptance did not close while preserving focus"
)

set_input("/no-such-command")
assert(not menu:update() and not menu:accept(), "no-match completion remained actionable")
set_input("/zzfixture")
assert(not menu:update(), "exact sole completion should close the menu")
set_input("ordinary prompt")
assert(not menu:update(), "ordinary input unexpectedly opened the menu")

set_input("/zzf")
assert(menu:update(), "menu did not reopen before invalid provider checks")
input_ref = nil
assert(not menu:update() and not menu:visible(), "invalid prompt window did not close the menu")
input_ref = input_win
parent_ref = nil
assert(not menu:open(), "invalid canvas window opened the menu")
parent_ref = parent_win

set_input("/zzf")
assert(menu:update(), "menu did not reopen before destroy")
local destroyed_buf = menu:buffer()
local destroyed_win = menu:window()
menu:destroy()
menu:destroy()
assert(not vim.api.nvim_buf_is_valid(destroyed_buf), "CommandMenu buffer survived destroy")
assert(not destroyed_win or not vim.api.nvim_win_is_valid(destroyed_win), "CommandMenu window survived destroy")
assert(
  menu:buffer() == nil and menu:window() == nil and not menu:owns_buffer(destroyed_buf),
  "destroy retained resources"
)

local scheduled_done = false
local scheduled_result = true
vim.schedule(function()
  scheduled_result = menu:update()
  scheduled_done = true
end)
assert(
  vim.wait(500, function()
    return scheduled_done
  end, 10),
  "scheduled post-destroy update did not run"
)
assert(
  not scheduled_result and menu:buffer() == nil and menu:window() == nil,
  "post-destroy update revived CommandMenu"
)

if vim.api.nvim_win_is_valid(input_win) then
  vim.api.nvim_win_close(input_win, true)
end
if vim.api.nvim_buf_is_valid(input_buf) then
  vim.api.nvim_buf_delete(input_buf, { force = true })
end
if vim.api.nvim_win_is_valid(parent_win) then
  vim.api.nvim_win_close(parent_win, true)
end
if vim.api.nvim_buf_is_valid(parent_buf) then
  vim.api.nvim_buf_delete(parent_buf, { force = true })
end

print("command_menu_spec: ok")
