local config = require("pi.config")
local context = require("pi.context")
local chat_ui = require("pi.ui.chat")
local Chat = chat_ui.Chat
local text_content = chat_ui.text_content
local dialog = require("pi.ui.dialog")

local M = {}
local clients = {}
local chats = {}

local function notify_error(err)
  vim.notify(err or "Unknown Pi error", vim.log.levels.ERROR, { title = "Pi" })
end

local rpc_unavailable_commands = {
  ["scoped-models"] = "Pi RPC 0.83 cannot change the model cycling scope; configure Pi's models setting in the Pi TUI.",
  import = "Pi RPC 0.83 cannot import external JSONL. Use /resume <path> for an existing Pi session.",
  share = "Pi RPC 0.83 cannot create a shared gist. Use /export or run /share in the Pi TUI.",
  changelog = "Pi RPC 0.83 does not expose the changelog view. Run /changelog in the Pi TUI.",
  trust = "Project trust cannot be changed inside an active RPC process. Update project_trust in pi.nvim setup and restart Pi.",
  login = "Authentication is not exposed by Pi RPC 0.83. Run pi in a terminal, use /login, then restart the Pi client.",
  logout = "Authentication is not exposed by Pi RPC 0.83. Run /logout in the Pi TUI, then restart the Pi client.",
  reload = "Pi RPC 0.83 cannot reload resources in place. Restart the Pi client after changing extensions, skills, or prompts.",
}

local function client_root()
  local bufnr = vim.api.nvim_get_current_buf()
  for root, chat in pairs(chats) do
    if bufnr == chat.buf or bufnr == chat.input_buf or bufnr == chat.status_buf then
      return root
    end
  end
  return context.root(bufnr, config.get().root_markers)
end

local function chat_for(root)
  if not chats[root] then
    chats[root] = Chat.new(root)
  end
  return chats[root]
end

local function refresh_commands(client)
  client:request("get_commands", {}, function(success, data)
    if success and data then
      local commands = data.commands or {}
      client.commands_by_name = {}
      for _, command in ipairs(commands) do
        if command.name then
          client.commands_by_name[command.name] = command
        end
      end
      chat_for(client.root):set_commands(commands)
    end
  end)
end

local function pending_display(client, message, display)
  if display ~= nil then
    return { text = display }
  end

  local command_name = message:match("^/([^%s]+)")
  if command_name then
    local command = client.commands_by_name and client.commands_by_name[command_name] or nil
    if not command or command.source == "extension" then
      return nil
    end
  end
  return { text = message }
end

local function remove_pending_display(queue, entry)
  if not entry then
    return
  end
  for index, candidate in ipairs(queue) do
    if candidate == entry then
      table.remove(queue, index)
      return
    end
  end
end

local function refresh_stats(client)
  if client.stats_pending then
    return
  end
  client.stats_pending = true
  client:request("get_session_stats", {}, function(success, data)
    client.stats_pending = false
    if success and data then
      chat_for(client.root):update_stats(data)
    end
  end)
end

local function refresh_state(client)
  client:request("get_state", {}, function(success, data)
    if success and data then
      client.session = data
      chat_for(client.root):update_state(data)
    end
  end)
end

local function reload_session(client)
  local chat = chat_for(client.root)
  chat.history_loaded = false
  chat:clear()
  chat:update_stats({ tokens = {}, contextUsage = {}, cost = 0 })
  refresh_state(client)
  refresh_stats(client)
  client:request("get_messages", {}, function(success, data)
    if success and data then
      chat:render_history(data.messages or {})
    end
  end)
end

local function attach(client)
  local display_queue = {}
  client.display_queue = display_queue

  client:on_event(function(event)
    local chat = chat_for(client.root)

    if event.type == "client_state" then
      if event.data then
        chat:update_state(event.data)
        refresh_stats(client)
        refresh_commands(client)
      else
        chat:set_activity(event.state)
      end
    elseif event.type == "history" then
      chat:render_history(event.messages)
    elseif event.type == "message_start" and event.message then
      if event.message.role == "user" then
        local pending = table.remove(display_queue, 1)
        local display = pending and pending.text or text_content(event.message.content)
        chat:add_user(display)
      elseif event.message.role == "assistant" then
        chat:start_assistant(event.message)
      end
    elseif event.type == "message_update" and event.message and event.message.role == "assistant" then
      chat:update_assistant(event.message)
    elseif event.type == "message_end" and event.message and event.message.role == "assistant" then
      chat:end_assistant(event.message)
    elseif event.type == "tool_execution_start" then
      chat:start_tool(event.toolCallId, event.toolName, event.args)
    elseif event.type == "tool_execution_update" then
      chat:update_tool(event.toolCallId, event.partialResult)
    elseif event.type == "tool_execution_end" then
      chat:end_tool(event.toolCallId, event.result, event.isError)
    elseif event.type == "bash_execution_update" then
      chat:append_bash_delta(event.id, event.delta)
    elseif event.type == "queue_update" then
      chat:set_queue(event)
    elseif event.type == "extension_ui_request" then
      dialog.handle(client, event, function(text)
        chat:open(false)
        chat:set_input(text)
      end)
    elseif event.type == "agent_start" then
      chat:set_activity("working")
    elseif event.type == "agent_settled" then
      chat:set_activity("idle")
      refresh_stats(client)
      context.refresh_unmodified(client.root)
    elseif event.type == "compaction_start" then
      chat:set_activity("compacting")
    elseif event.type == "compaction_end" then
      chat:set_activity(event.willRetry and "working" or "idle")
      if event.result then
        chat:add_status(
          ("Context compacted: %s → ~%s tokens"):format(
            event.result.tokensBefore or "?",
            event.result.estimatedTokensAfter or "?"
          )
        )
      elseif event.errorMessage then
        chat:add_status(event.errorMessage, true)
      end
      refresh_stats(client)
    elseif event.type == "auto_retry_start" then
      chat:set_activity(("retry %d/%d"):format(event.attempt or 0, event.maxAttempts or 0))
    elseif event.type == "auto_retry_end" and not event.success then
      chat:add_status(event.finalError or "Retry failed", true)
    elseif event.type == "extension_error" then
      chat:add_status(event.error or "Extension error", true)
    elseif event.type == "client_error" then
      chat:set_activity("error")
      notify_error(event.error)
    elseif event.type == "client_exit" and not event.expected then
      chat:set_activity("error")
      local suffix = event.stderr ~= "" and ("\n" .. event.stderr) or ""
      notify_error(("Pi exited with code %s%s"):format(event.code, suffix))
    elseif event.type == "response" and event.success == false then
      notify_error(event.error)
    end
  end)
end

local function get_client(root)
  root = root or client_root()
  if not clients[root] then
    -- Resolve Client lazily so tests can replace pi.client in
    -- package.loaded after pi.runtime has been cached (the plugin's
    -- BufEnter autocmd loads the full chain at startup).
    local Client = require("pi.client").Client
    local client = Client.new(root)
    clients[root] = client
    attach(client)
    client:start()
  end
  return clients[root]
end

local function with_prompt(text, callback)
  if text and vim.trim(text) ~= "" then
    callback(vim.trim(text))
    return
  end
  vim.ui.input({ prompt = "Pi: " }, function(input)
    if input and vim.trim(input) ~= "" then
      callback(vim.trim(input))
    end
  end)
end

local function send_prompt(message, display, root, behavior)
  local client = get_client(root)
  local display_entry = pending_display(client, message, display)
  if display_entry then
    table.insert(client.display_queue, display_entry)
  end
  local payload = { message = message }
  if behavior == "followUp" and (client.state == "streaming" or client.state == "compacting") then
    payload.streamingBehavior = "followUp"
  elseif behavior == "steer" or client.state == "streaming" or client.state == "compacting" then
    payload.streamingBehavior = "steer"
  end
  client:request("prompt", payload, function(success, _, err)
    if not success then
      remove_pending_display(client.display_queue, display_entry)
      notify_error(err)
    end
  end)
  chat_for(client.root):open(false)
end

M.clients = clients
M.chats = chats
M.notify_error = notify_error
M.rpc_unavailable_commands = rpc_unavailable_commands
M.client_root = client_root
M.chat_for = chat_for
M.refresh_commands = refresh_commands
M.refresh_stats = refresh_stats
M.refresh_state = refresh_state
M.reload_session = reload_session
M.get_client = get_client
M.with_prompt = with_prompt
M.send_prompt = send_prompt

return M
