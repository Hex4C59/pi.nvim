local config = require("pi.config")
local context = require("pi.context")
local runtime = require("pi.runtime")

local M = {}

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
        .. (" [%s:%d-%d]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"), first_line, last_line),
      root
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
      prompt .. (" [%s]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")),
      root
    )
  end)
end

function M.abort(root)
  runtime.abort(root)
end

function M.bash(command, root)
  command = vim.trim(command or "")
  if command == "" then
    return
  end
  runtime.run_bash(command, root)
end

return M
