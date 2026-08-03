local action = require("pi.commands.action")
local runtime = require("pi.runtime")
local original_client_root = runtime.client_root
local original_chat_for = runtime.chat_for
local original_with_prompt = runtime.with_prompt
local original_send_prompt = runtime.send_prompt
local original_buf = vim.api.nvim_get_current_buf()
local captured_roots = {}
local deferred_prompt
local action_buf

local function run()
  runtime.client_root = function()
    return "/project-a"
  end
  runtime.chat_for = function()
    return { set_path = function() end }
  end
  runtime.with_prompt = function(_, callback)
    deferred_prompt = callback
  end
  runtime.send_prompt = function(_, _, prompt_root)
    table.insert(captured_roots, prompt_root)
  end
  action_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(action_buf, "/project-a/example.lua")
  vim.api.nvim_buf_set_lines(action_buf, 0, -1, false, { "local value = true" })
  vim.api.nvim_set_current_buf(action_buf)
  action.visual("", 1, 1)
  deferred_prompt("review")
  action.buffer("")
  deferred_prompt("review")
end

local ok, err = xpcall(run, debug.traceback)
runtime.client_root = original_client_root
runtime.chat_for = original_chat_for
runtime.with_prompt = original_with_prompt
runtime.send_prompt = original_send_prompt
if vim.api.nvim_buf_is_valid(original_buf) then
  pcall(vim.api.nvim_set_current_buf, original_buf)
end
if action_buf and vim.api.nvim_buf_is_valid(action_buf) then
  pcall(vim.api.nvim_buf_delete, action_buf, { force = true })
end
if not ok then
  error(err)
end
assert(vim.deep_equal(captured_roots, { "/project-a", "/project-a" }), "async context actions changed project roots")

print("action_spec: ok")
