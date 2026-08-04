local dialog = require("pi.ui.dialog")

local original_columns = vim.o.columns
local original_lines = vim.o.lines
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

  local function response_for(id)
    for _, entry in ipairs(responses) do
      if entry.id == id then
        return entry.response
      end
    end
  end

  local function response_count(id)
    local count = 0
    for _, entry in ipairs(responses) do
      if entry.id == id then
        count = count + 1
      end
    end
    return count
  end

  local function mapping(bufnr, lhs, mode)
    for _, item in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or "n")) do
      if item.lhs:lower() == lhs:lower() then
        return item.callback
      end
    end
  end

  local function current_dialog_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    assert(vim.b[bufnr].pi_kind == "extension_dialog", "native Extension dialog buffer is missing")
    return bufnr
  end

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

  local reported_title
  dialog.handle(client, { method = "setTitle", title = "Focused task" }, {
    set_title = function(title)
      reported_title = title
    end,
  })
  assert(reported_title == "Focused task", "setTitle was not routed")
  assert(#responses == 0, "fire-and-forget Extension UI methods sent an RPC response")

  dialog.handle(client, {
    id = "native-select",
    method = "select",
    title = "Choose",
    options = { "first", "second" },
  })
  local select_buf = current_dialog_buffer()
  assert(mapping(select_buf, "j"), "native select navigation mapping is missing")()
  assert(mapping(select_buf, "<CR>"), "native select submit mapping is missing")()
  assert(response_for("native-select").value == "second", "native select returned the wrong option")

  dialog.handle(client, { id = "native-confirm", method = "confirm", title = "Confirm", message = "Continue?" })
  local confirm_buf = current_dialog_buffer()
  assert(mapping(confirm_buf, "y"), "native confirmation mapping is missing")()
  assert(response_for("native-confirm").confirmed == true, "native confirmation did not return true")

  dialog.handle(client, { id = "confirm-cancel", method = "confirm", title = "Confirm", message = "Continue?" })
  local cancel_confirm_buf = current_dialog_buffer()
  assert(mapping(cancel_confirm_buf, "q"), "native confirmation cancel mapping is missing")()
  assert(response_for("confirm-cancel").confirmed == false, "cancelled confirmation did not fail closed")

  dialog.handle(client, {
    id = "native-input",
    method = "input",
    title = "Name",
    placeholder = "placeholder must not become a value",
  })
  local input_buf = current_dialog_buffer()
  assert(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "", "input placeholder leaked into buffer text")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "entered value" })
  assert(mapping(input_buf, "<CR>"), "native input submit mapping is missing")()
  assert(response_for("native-input").value == "entered value", "native input lost submitted text")

  dialog.handle(client, { id = "cancelled-by-server", method = "select", title = "Cancel", options = { "late" } })
  local server_cancel_buf = current_dialog_buffer()
  local late_submit = assert(mapping(server_cancel_buf, "<CR>"), "select submit mapping is missing")
  assert(dialog.cancel(client, "cancelled-by-server"), "server cancellation did not find its request")
  late_submit()
  assert(response_for("cancelled-by-server") == nil, "callback after server cancellation sent a response")
  assert(not dialog.cancel(client, "cancelled-by-server"), "server cancellation was accepted twice")

  dialog.handle(client, { id = "queue-first", method = "input", title = "First" })
  local first_buf = current_dialog_buffer()
  dialog.handle(client, { id = "queue-second", method = "select", title = "Second", options = { "queued" } })
  assert(vim.api.nvim_get_current_buf() == first_buf, "a simultaneous generic dialog bypassed the queue")
  vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { "first value" })
  assert(mapping(first_buf, "<CR>"), "queued input submit mapping is missing")()
  local second_buf = current_dialog_buffer()
  assert(second_buf ~= first_buf, "queued dialog was not activated after the first response")
  assert(mapping(second_buf, "<CR>"), "queued select submit mapping is missing")()
  assert(response_for("queue-first").value == "first value", "first queued response lost correlation")
  assert(response_for("queue-second").value == "queued", "second queued response lost correlation")

  local permission_callback
  local cancelled_permission
  dialog.handle(client, {
    id = "permission-select",
    method = "select",
    title = "Bash command\ngit status --short",
    options = { "Block", "Allow once", "Allow for session" },
  }, {
    permission_select = function(request, callback)
      assert(request.title == "Bash command", "permission title was not separated for presentation")
      assert(request.message == "git status --short", "permission detail was lost")
      permission_callback = callback
    end,
    cancel_permission = function(id)
      cancelled_permission = id
      permission_callback(false)
    end,
  })
  vim.wait(10)
  assert(response_for("permission-select") == nil, "permission request acquired an implicit timeout")
  assert(dialog.cancel(client, "permission-select"), "server did not cancel the permission presentation")
  assert(cancelled_permission == "permission-select", "permission cancellation targeted the wrong request")
  assert(response_for("permission-select") == nil, "server-cancelled permission request sent a late response")

  for _, case in ipairs({
    { id = "editor-tiny", columns = 20, lines = 10, floating = false },
    { id = "editor-small", columns = 40, lines = 12, floating = false },
    { id = "editor-normal", columns = 100, lines = 32, floating = true },
    { id = "editor-wide", columns = 180, lines = 55, floating = true },
  }) do
    vim.o.columns = case.columns
    vim.o.lines = case.lines
    local previous_win = vim.api.nvim_get_current_win()
    local previous_buf = vim.api.nvim_get_current_buf()
    if not case.floating then
      vim.wo[previous_win].wrap = true
      vim.wo[previous_win].cursorline = true
    end
    dialog.handle(client, {
      id = case.id,
      method = "editor",
      title = string.rep("Long title ", 20),
      prefill = "responsive",
    })
    local editor_win = vim.api.nvim_get_current_win()
    local editor_buf = current_dialog_buffer()
    local config = vim.api.nvim_win_get_config(editor_win)
    assert((config.relative ~= "") == case.floating, "editor chose the wrong responsive layout: " .. case.id)
    if case.floating then
      assert(config.row >= 0 and config.col >= 0, "editor float used a negative origin: " .. case.id)
      assert(config.width + 2 <= case.columns, "editor float exceeded available columns: " .. case.id)
      assert(config.height + 2 < case.lines, "editor float exceeded available rows: " .. case.id)
      local title = type(config.title) == "table" and config.title[1][1] or config.title
      assert(vim.fn.strdisplaywidth(title or "") <= config.width - 2, "editor title exceeded the float: " .. case.id)
    else
      assert(editor_win == previous_win, "small editor did not reuse the current window: " .. case.id)
      assert(editor_buf ~= previous_buf, "small editor did not install its scratch buffer: " .. case.id)
    end
    assert(mapping(editor_buf, "q"), "responsive editor cancel mapping is missing: " .. case.id)()
    assert(response_for(case.id).cancelled, "responsive editor cancellation did not resolve: " .. case.id)
    if not case.floating then
      assert(
        vim.api.nvim_win_get_buf(previous_win) == previous_buf,
        "small editor did not restore its buffer: " .. case.id
      )
      assert(vim.wo[previous_win].wrap, "small editor did not restore 'wrap': " .. case.id)
      assert(vim.wo[previous_win].cursorline, "small editor did not restore 'cursorline': " .. case.id)
    end
  end
  vim.o.columns = original_columns
  vim.o.lines = original_lines

  dialog.handle(client, { id = "editor-submit", method = "editor", title = "Edit", prefill = "first" })
  local editor_buf = current_dialog_buffer()
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "first", "second" })
  assert(mapping(editor_buf, "<C-S>"), "editor submit mapping is missing")()
  assert(response_for("editor-submit").value == "first\nsecond", "multi-line editor submission lost content")

  dialog.handle(client, { id = "editor-window-close", method = "editor", title = "Close", prefill = "draft" })
  local closed_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(closed_win, true)
  assert(response_for("editor-window-close").cancelled, "closing the editor window left its RPC request pending")

  dialog.handle(client, { id = "editor-buffer-wipe", method = "editor", title = "Wipe", prefill = "draft" })
  local wiped_buf = current_dialog_buffer()
  vim.api.nvim_buf_delete(wiped_buf, { force = true })
  assert(response_for("editor-buffer-wipe").cancelled, "wiping the editor buffer left its RPC request pending")

  dialog.handle(client, { id = "discard-active", method = "input", title = "Active" })
  dialog.handle(client, { id = "discard-queued", method = "input", title = "Queued" })
  local discarded_buf = current_dialog_buffer()
  dialog.discard(client)
  assert(not vim.api.nvim_buf_is_valid(discarded_buf), "discard left an active native dialog open")
  assert(response_for("discard-active") == nil and response_for("discard-queued") == nil, "discard sent a response")

  for _, id in ipairs({
    "native-select",
    "native-confirm",
    "confirm-cancel",
    "native-input",
    "queue-first",
    "queue-second",
  }) do
    assert(response_count(id) == 1, "dialog responded more than once: " .. id)
  end
end

local ok, err = xpcall(run, debug.traceback)
vim.o.columns = original_columns
vim.o.lines = original_lines
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if not original_buffers[buf] and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
if not ok then
  error(err)
end

print("dialog_spec: ok")
