local action = require("pi.commands.action")
local runtime = require("pi.runtime")
local original_client_root = runtime.client_root
local original_chat_for = runtime.chat_for
local original_with_prompt = runtime.with_prompt
local original_send_prompt = runtime.send_prompt
local captured_roots = {}
local deferred_prompt
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
local action_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(action_buf, "/project-a/example.lua")
vim.api.nvim_buf_set_lines(action_buf, 0, -1, false, { "local value = true" })
vim.api.nvim_set_current_buf(action_buf)
action.visual("", 1, 1)
deferred_prompt("review")
action.buffer("")
deferred_prompt("review")
runtime.client_root = original_client_root
runtime.chat_for = original_chat_for
runtime.with_prompt = original_with_prompt
runtime.send_prompt = original_send_prompt
assert(vim.deep_equal(captured_roots, { "/project-a", "/project-a" }), "async context actions changed project roots")

print("action_spec: ok")
