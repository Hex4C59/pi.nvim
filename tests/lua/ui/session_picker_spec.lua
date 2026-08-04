local picker_module = require("pi.ui.session_picker")

local previous_columns = vim.o.columns
local previous_lines = vim.o.lines
local selected
local more_cursor

local function invoke(key)
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(type(mapping.callback) == "function", "session picker mapping has no Lua callback: " .. key)
  mapping.callback()
end

local function run()
  vim.o.columns = 100
  vim.o.lines = 32
  local picker = picker_module.open({
    sessions = {
      {
        path = "/sessions/a.jsonl",
        cwd = "/project",
        name = "Named session",
        messageCount = 12,
        model = { provider = "fixture", id = "model-a" },
        updatedAt = "2026-08-04T08:30:00.000Z",
      },
    },
    next_cursor = "cursor-1",
    on_select = function(session)
      selected = session
    end,
    on_more = function(cursor)
      more_cursor = cursor
    end,
    on_path = function() end,
  })
  assert(picker.floating, "normal viewport did not use the native floating session picker")
  local lines = vim.api.nvim_buf_get_lines(picker.buf, 0, -1, false)
  assert(lines[1]:find("Named session", 1, true), "session picker omitted the authoritative name")
  assert(lines[1]:find("12 msgs", 1, true), "session picker omitted the message count")
  assert(lines[1]:find("fixture/model-a", 1, true), "session picker omitted the model")
  assert(lines[1]:find("2026-08-04 08:30", 1, true), "session picker omitted the update date")

  picker:append(
    { picker.sessions[1], { path = "/sessions/b.jsonl", cwd = "/project", preview = "Second" } },
    "cursor-2"
  )
  assert(#picker.sessions == 2, "session pagination did not suppress duplicate paths")
  picker.selected = 3
  invoke("<CR>")
  assert(more_cursor == "cursor-2" and picker.loading, "load-more row did not request the opaque cursor once")
  picker:set_error("fixture failure")
  assert(picker.error == "fixture failure" and not picker.loading, "pagination failure was not retryable")
  picker:append({ { path = "/sessions/c.jsonl", cwd = "/project" } }, nil)
  assert(#picker.sessions == 3 and picker.next_cursor == nil, "final page did not settle picker pagination")
  picker.selected = 2
  invoke("<CR>")
  assert(selected and selected.path == "/sessions/b.jsonl", "picker selection lost its structured session item")
  assert(picker.closed, "session picker did not close after selection")

  vim.o.columns = 40
  vim.o.lines = 9
  local original_buf = vim.api.nvim_get_current_buf()
  local compact = picker_module.open({
    sessions = {},
    on_select = function() end,
    on_more = function() end,
    on_path = function() end,
  })
  assert(not compact.floating, "tiny viewport did not use the current-window fallback")
  compact:close()
  assert(vim.api.nvim_get_current_buf() == original_buf, "current-window picker did not restore the previous buffer")
end

local ok, err = xpcall(run, debug.traceback)
vim.o.columns = previous_columns
vim.o.lines = previous_lines
if not ok then
  error(err)
end
print("session_picker_spec: ok")
