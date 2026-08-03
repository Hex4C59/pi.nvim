local config = require("pi.config")
local context = require("pi.context")
local runtime = require("pi.runtime")

local M = {}

local notify_error = runtime.notify_error

function M.ask(text, root)
  if not root then
    local path = vim.api.nvim_buf_get_name(0)
    root = runtime.client_root()
    runtime.chat_for(root):set_path(path)
  end
  runtime.with_prompt(text, function(prompt)
    runtime.send_prompt(prompt, nil, root)
  end)
end

function M.visual(text, first_line, last_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = runtime.client_root()
  runtime.chat_for(root):set_path(vim.api.nvim_buf_get_name(bufnr))
  local selected = context.range(bufnr, root, first_line, last_line, config.get().context)
  runtime.with_prompt(text, function(prompt)
    runtime.send_prompt(
      selected .. "\n\nUser request:\n" .. prompt,
      prompt
        .. (" [%s:%d-%d]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"), first_line, last_line)
    )
  end)
end

function M.buffer(text)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = runtime.client_root()
  runtime.chat_for(root):set_path(vim.api.nvim_buf_get_name(bufnr))
  local buffer_context = context.buffer(bufnr, root, config.get().context)
  runtime.with_prompt(text, function(prompt)
    runtime.send_prompt(
      buffer_context .. "\n\nUser request:\n" .. prompt,
      prompt .. (" [%s]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"))
    )
  end)
end

function M.abort(root)
  local client = runtime.get_client(root)
  local command = client.bash_running and "abort_bash" or "abort"
  client:request(command, {}, function(success, _, err)
    if not success then
      notify_error(err)
    end
  end)
end

function M.copy_last_response(root)
  runtime.chat_for(root or runtime.client_root()):copy_last_assistant()
end

function M.bash(command, root)
  command = vim.trim(command or "")
  if command == "" then
    return
  end
  local client = runtime.get_client(root)
  local chat = runtime.chat_for(client.root)
  local request_id
  request_id = client:request("bash", { command = command }, function(success, data, err)
    client.bash_running = nil
    if not request_id then
      if not success then
        notify_error(err or "Unable to start Bash command")
      end
      return
    end
    if not success then
      chat:end_tool(request_id, { content = { { type = "text", text = err or "Bash failed" } } }, true)
    else
      data = data or {}
      chat:end_bash(request_id, data, (data.exitCode or 0) ~= 0)
    end
  end, 0)
  if request_id then
    client.bash_running = request_id
    chat:start_tool(request_id, "bash", { command = command })
  end
end

return M
