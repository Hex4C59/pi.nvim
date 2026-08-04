local admin = require("pi.ui.admin")

local original_columns = vim.o.columns
local original_lines = vim.o.lines
local original_paste = vim.paste
local sensitive_surface

local function mapping(buf, lhs, mode)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or "n")) do
    if item.lhs:lower() == lhs:lower() then
      return item.callback
    end
  end
end

local function buffers_contain(needle)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find(needle, 1, true) then
        return true
      end
    end
  end
  return false
end

local function run()
  vim.o.columns = 100
  vim.o.lines = 32

  local submitted
  local secret = "fixture-secret-value"
  local surface = admin.input({
    title = "Provider secret",
    sensitive = true,
    on_submit = function(value)
      submitted = value
    end,
  })
  sensitive_surface = surface
  assert(vim.b[surface.buf].pi_sensitive == true, "secret input did not carry structural sensitivity metadata")
  assert(vim.bo[surface.buf].swapfile == false, "secret input enabled a swap file")
  assert(vim.bo[surface.buf].undofile == false, "secret input enabled persistent undo")
  assert(vim.api.nvim_paste(secret, false, -1), "Neovim rejected sensitive input paste")
  local mask = string.rep("*", #secret)
  assert(surface.secret == secret, "sensitive paste did not update the memory-only value")
  assert(
    vim.api.nvim_buf_get_lines(surface.buf, 0, 1, false)[1] == mask,
    "secret input buffer contains something other than its mask"
  )
  assert(not buffers_contain(secret), "secret input leaked its value into a Neovim buffer")
  local submit = assert(mapping(surface.buf, "<CR>", "i"), "secret input submit mapping is missing")
  submit()
  assert(submitted == secret, "secret input did not return its in-memory value")
  assert(surface.closed and not vim.api.nvim_buf_is_valid(surface.buf), "secret input did not wipe its scratch buffer")
  assert(vim.paste == original_paste, "secret input did not restore Neovim's paste handler")
  assert(not buffers_contain(secret), "submitted secret remained in a Neovim buffer")
  sensitive_surface = nil
  submitted = nil
  secret = nil

  local selected
  local picker = admin.multi_select({
    title = "Model scope",
    items = {
      { provider = "fixture", id = "one" },
      { provider = "fixture", id = "two" },
    },
    selected = { { provider = "fixture", id = "one" } },
    on_select = function(models)
      selected = models
    end,
  })
  local lines = vim.api.nvim_buf_get_lines(picker.buf, 0, -1, false)
  assert(lines[1]:find("[x] fixture/one", 1, true), "model scope omitted the enabled marker")
  assert(lines[2]:find("[ ] fixture/two", 1, true), "model scope omitted the disabled marker")
  assert(mapping(picker.buf, " "), "model scope toggle mapping is missing")()
  assert(mapping(picker.buf, "j"), "model scope navigation mapping is missing")()
  assert(mapping(picker.buf, " "), "model scope second toggle mapping is missing")()
  assert(mapping(picker.buf, "<CR>"), "model scope submit mapping is missing")()
  assert(#selected == 1 and selected[1].id == "two", "model scope returned the wrong structured selection")

  local empty_count = 0
  local empty_picker = admin.multi_select({
    items = { { provider = "fixture", id = "one" } },
    selected = {},
    on_empty = function()
      empty_count = empty_count + 1
    end,
  })
  assert(mapping(empty_picker.buf, "<CR>"), "empty model scope submit mapping is missing")()
  assert(empty_count == 1 and not empty_picker.closed, "empty model scope closed or changed state")
  assert(mapping(empty_picker.buf, "q"), "empty model scope cancel mapping is missing")()

  local changelog = admin.show_markdown({ title = string.rep("Long changelog ", 20), lines = { "# Pi 0.83.0" } })
  assert(changelog.floating, "normal viewport did not use a native administrative float")
  local config = vim.api.nvim_win_get_config(changelog.win)
  local title = type(config.title) == "table" and config.title[1][1] or config.title
  assert(vim.fn.strdisplaywidth(title or "") <= config.width - 2, "administrative title overflowed its float")
  assert(vim.bo[changelog.buf].modifiable == false, "changelog view is writable")
  assert(mapping(changelog.buf, "q"), "changelog close mapping is missing")()

  vim.o.columns = 40
  vim.o.lines = 9
  local previous_buf = vim.api.nvim_get_current_buf()
  local compact = admin.show_markdown({ title = "Pi changelog", lines = { "small viewport" } })
  assert(not compact.floating, "tiny viewport did not use the current-window fallback")
  compact:close()
  assert(vim.api.nvim_get_current_buf() == previous_buf, "administrative fallback did not restore its buffer")
end

local ok, err = xpcall(run, debug.traceback)
if sensitive_surface then
  pcall(sensitive_surface.close, sensitive_surface)
end
vim.o.columns = original_columns
vim.o.lines = original_lines
vim.paste = original_paste
if not ok then
  error(err)
end

print("admin_spec: ok")
