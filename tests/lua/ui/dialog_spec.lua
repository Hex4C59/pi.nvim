local dialog = require("pi.ui.dialog")

local original_select = vim.ui.select
local original_buffers = {}
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  original_buffers[buf] = true
end

local function run()
  local editor_values = {}
  local responses = {}
  local client = {
    respond_ui = function(_, id, response)
      table.insert(responses, { id = id, response = response })
    end,
  }

  dialog.handle(client, { id = "draft", method = "set_editor_text", text = "prefilled text" }, function(text)
    table.insert(editor_values, text)
  end)
  dialog.handle(client, { id = "clear", method = "set_editor_text", text = "" }, function(text)
    table.insert(editor_values, text)
  end)

  assert(
    vim.deep_equal(editor_values, { "prefilled text", "" }),
    "set_editor_text did not prefill and clear the editor"
  )
  assert(#responses == 0, "fire-and-forget editor updates must not send an RPC response")

  local function response_for(id)
    for _, entry in ipairs(responses) do
      if entry.id == id then
        return entry.response
      end
    end
  end

  local reported_status = {}
  dialog.handle(client, {
    method = "setStatus",
    statusKey = "pi.permission_mode",
    statusText = "auto",
  }, {
    set_status = function(key, value)
      reported_status = { key, value }
    end,
  })
  assert(vim.deep_equal(reported_status, { "pi.permission_mode", "auto" }), "setStatus was not routed")
  assert(#responses == 0, "setStatus must not send an RPC response")

  local reported_widget = {}
  dialog.handle(client, {
    method = "setWidget",
    widgetKey = "pi.todo",
    widgetLines = { "Tasks", "○ #1 Test" },
    widgetPlacement = "aboveEditor",
  }, {
    set_widget = function(key, lines, placement)
      reported_widget = { key, lines, placement }
    end,
  })
  assert(
    vim.deep_equal(reported_widget, { "pi.todo", { "Tasks", "○ #1 Test" }, "aboveEditor" }),
    "setWidget was not routed"
  )
  assert(#responses == 0, "setWidget must not send an RPC response")

  local reported_title
  dialog.handle(client, { method = "setTitle", title = "Focused task" }, {
    set_title = function(title)
      reported_title = title
    end,
  })
  assert(reported_title == "Focused task", "setTitle was not routed")
  assert(#responses == 0, "setTitle must not send an RPC response")

  local permission_request
  dialog.handle(client, {
    id = "permission-select",
    method = "select",
    title = "Bash command\ngit status --short",
    options = { "Block", "Allow once", "Allow for session" },
  }, {
    permission_select = function(request, callback)
      permission_request = request
      callback("Allow for session")
      callback("Block")
    end,
  })
  assert(permission_request.title == "Bash command", "permission title was not separated for presentation")
  assert(permission_request.message == "git status --short", "permission detail was lost")
  assert(response_for("permission-select").value == "Allow for session", "raw permission choice was not returned")
  local permission_responses = 0
  for _, entry in ipairs(responses) do
    if entry.id == "permission-select" then
      permission_responses = permission_responses + 1
    end
  end
  assert(permission_responses == 1, "permission select responded more than once")

  vim.ui.select = function()
    error("custom confirmation handler must bypass vim.ui.select")
  end
  local confirmation_request = nil
  dialog.handle(client, { id = "confirm-cancel", method = "confirm", title = "Confirm" }, {
    confirm = function(request, callback)
      confirmation_request = request
      callback(false)
      callback(true)
    end,
  })
  vim.ui.select = original_select
  assert(
    confirmation_request and confirmation_request.title == "Confirm",
    "confirmation request was not routed to the custom UI"
  )
  assert(response_for("confirm-cancel").confirmed == false, "cancelled confirmation did not resolve as false")
  local confirm_responses = 0
  for _, entry in ipairs(responses) do
    if entry.id == "confirm-cancel" then
      confirm_responses = confirm_responses + 1
    end
  end
  assert(confirm_responses == 1, "confirmation request responded more than once")

  dialog.handle(client, { id = "confirm-no-ui", method = "confirm", title = "Confirm" })
  assert(response_for("confirm-no-ui").confirmed == false, "missing confirmation UI did not fail closed")

  local function mapping(bufnr, lhs)
    for _, item in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if item.lhs:lower() == lhs:lower() then
        return item.callback
      end
    end
  end

  dialog.handle(client, { id = "editor-submit", method = "editor", title = "Edit", prefill = "first" })
  local editor_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "first", "second" })
  assert(mapping(editor_buf, "<C-S>"), "editor submit mapping is missing")()
  assert(response_for("editor-submit").value == "first\nsecond", "multi-line editor submission lost content")

  dialog.handle(client, { id = "editor-cancel", method = "editor", title = "Cancel", prefill = "draft" })
  local cancel_buf = vim.api.nvim_get_current_buf()
  assert(mapping(cancel_buf, "q"), "editor cancel mapping is missing")()
  assert(response_for("editor-cancel").cancelled, "editor cancellation did not return the cancelled response")

  dialog.handle(client, { id = "editor-window-close", method = "editor", title = "Close", prefill = "draft" })
  local closed_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(closed_win, true)
  assert(response_for("editor-window-close").cancelled, "closing the editor window left its RPC request pending")

  dialog.handle(client, { id = "editor-buffer-wipe", method = "editor", title = "Wipe", prefill = "draft" })
  local wiped_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_delete(wiped_buf, { force = true })
  assert(response_for("editor-buffer-wipe").cancelled, "wiping the editor buffer left its RPC request pending")
end

local ok, err = xpcall(run, debug.traceback)
vim.ui.select = original_select
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if not original_buffers[buf] and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
if not ok then
  error(err)
end

print("dialog_spec: ok")
