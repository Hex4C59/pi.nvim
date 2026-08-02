local dialog = require("pi.ui.dialog")

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

assert(vim.deep_equal(editor_values, { "prefilled text", "" }), "set_editor_text did not prefill and clear the editor")
assert(#responses == 0, "fire-and-forget editor updates must not send an RPC response")

local function response_for(id)
  for _, entry in ipairs(responses) do
    if entry.id == id then
      return entry.response
    end
  end
end

local original_select = vim.ui.select
vim.ui.select = function(_, _, callback)
  callback(nil)
end
dialog.handle(client, { id = "confirm-cancel", method = "confirm", title = "Confirm" })
vim.ui.select = original_select
assert(response_for("confirm-cancel").confirmed == false, "cancelled confirmation did not resolve as false")

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

print("dialog_spec: ok")
