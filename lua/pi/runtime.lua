local config = require("pi.config")
local context = require("pi.context")
local chat_ui = require("pi.ui.chat")
local Chat = chat_ui.Chat
local text_content = require("pi.message").text_content
local dialog = require("pi.ui.dialog")

local M = {}
local clients = {}
local chats = {}
local projects = {}

local function client_is_current(client)
  return client and clients[client.root] == client
end

local function project_for_client(client)
  local project = client and projects[client.root] or nil
  if project and project.client == client then
    return project
  end
  return nil
end

local function project_is_current(project)
  return project and projects[project.client.root] == project and client_is_current(project.client)
end

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
    if chat:owns_buffer(bufnr) then
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
  local project = project_for_client(client)
  if not project then
    return
  end
  client:request("get_commands", {}, function(success, data)
    if project_is_current(project) and success and data then
      local commands = data.commands or {}
      project.commands_by_name = {}
      for _, command in ipairs(commands) do
        if command.name then
          project.commands_by_name[command.name] = command
        end
      end
      chat_for(client.root):set_commands(commands)
    end
  end)
end

local function pending_display(project, message, display, images)
  if display ~= nil then
    return { text = display, images = images }
  end

  local command_name = message:match("^/([^%s]+)")
  if command_name then
    local command = project.commands_by_name[command_name]
    if not command or command.source == "extension" then
      return nil
    end
  end
  return { text = message, images = images }
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
  local project = project_for_client(client)
  if not project or project.stats_pending then
    return
  end
  project.stats_pending = true
  client:request("get_session_stats", {}, function(success, data)
    project.stats_pending = false
    if project_is_current(project) and success and data then
      chat_for(client.root):update_stats(data)
    end
  end)
end

local function refresh_state(client)
  client:request("get_state", {}, function(success, data)
    if client_is_current(client) and success and data then
      client.session = data
      chat_for(client.root):update_state(data)
    end
  end)
end

local function reload_session(client)
  local chat = chat_for(client.root)
  chat:reset_session_projection()
  refresh_state(client)
  refresh_stats(client)
  client:request("get_messages", {}, function(success, data)
    if client_is_current(client) and success and data then
      chat:render_history(data.messages or {})
    end
  end)
end

local function attach(client)
  local project = {
    client = client,
    display_queue = {},
    commands_by_name = {},
    stats_pending = false,
    direct_bash_request_id = nil,
    unsubscribe = nil,
  }
  projects[client.root] = project

  project.unsubscribe = client:on_event(function(event)
    if not project_is_current(project) then
      return
    end
    local chat = chat_for(client.root)

    if event.type == "client_state" then
      if event.data then
        chat:update_state(event.data)
        refresh_stats(client)
        refresh_commands(client)
      else
        if event.state == "starting" then
          chat:reset_permission_mode()
        end
        chat:set_activity(event.state)
      end
    elseif event.type == "history" then
      chat:render_history(event.messages)
    elseif event.type == "message_start" and event.message then
      if event.message.role == "user" then
        local pending = table.remove(project.display_queue, 1)
        local display = pending and pending.text or text_content(event.message.content)
        local content = event.message.content
        if (type(content) ~= "table" or #content == 0) and pending and pending.images then
          content = pending.images
        end
        chat:add_user(display, content)
      elseif event.message.role == "assistant" then
        chat:start_assistant(event.message)
      end
    elseif event.type == "message_update" and event.message and event.message.role == "assistant" then
      chat:update_assistant(event.message, event.assistantMessageEvent)
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
      dialog.handle(client, event, {
        permission_select = function(request, respond)
          chat:select_permission(request, respond)
        end,
        confirm = function(request, respond)
          chat:confirm(request, respond)
        end,
        set_status = function(key, value)
          if key == "pi.permission_mode" then
            chat:update_permission_mode(value)
          end
        end,
        set_widget = function(key, lines, placement)
          chat:set_widget(key, lines, placement)
        end,
        set_title = function(title)
          chat:set_title(title)
        end,
        set_editor_text = function(text)
          chat:open(false)
          chat:set_input(text)
        end,
      })
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
    elseif event.type == "client_exit" then
      project.direct_bash_request_id = nil
      dialog.discard(client)
      chat:reset_permission_mode()
      chat:clear_widgets()
      if not event.expected then
        chat:set_activity("error")
        local suffix = event.stderr ~= "" and ("\n" .. event.stderr) or ""
        notify_error(("Pi exited with code %s%s"):format(event.code, suffix))
      end
    elseif event.type == "response" and event.success == false and not event._pi_request_matched then
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

local function send_prompt(message, display, root, behavior, images)
  local client = get_client(root)
  local project = project_for_client(client)
  local chat = chat_for(client.root)
  if type(images) == "table" and #images > 0 then
    local valid, validation_err = chat:validate_image_attachments(images)
    if not valid then
      notify_error(validation_err)
      return nil
    end
  end
  local display_entry = pending_display(project, message, display, images)
  if display_entry then
    table.insert(project.display_queue, display_entry)
  end
  local payload = { message = message }
  if type(images) == "table" and #images > 0 then
    payload.images = images
  end
  if behavior == "followUp" and (client.state == "streaming" or client.state == "compacting") then
    payload.streamingBehavior = "followUp"
  elseif behavior == "steer" or client.state == "streaming" or client.state == "compacting" then
    payload.streamingBehavior = "steer"
  end
  client:request("prompt", payload, function(success, _, err)
    if not project_is_current(project) then
      return
    end
    if not success then
      remove_pending_display(project.display_queue, display_entry)
      if type(images) == "table" and #images > 0 then
        local _, restore_err = chat:restore_image_attachments(images)
        if restore_err then
          err = (err or "Prompt failed") .. "; " .. restore_err
        end
      end
      notify_error(err)
    elseif display_entry and type(images) == "table" and #images > 0 then
      display_entry.images = chat:localize_images(images)
      images = nil
    end
  end)
  chat:open(false)
end

local function abort(root)
  local client = get_client(root)
  local project = project_for_client(client)
  local command = project and project.direct_bash_request_id and "abort_bash" or "abort"
  client:request(command, {}, function(success, _, err)
    if not success and project_is_current(project) then
      notify_error(err)
    end
  end)
end

local function run_bash(command, root)
  local client = get_client(root)
  local project = project_for_client(client)
  local chat = chat_for(client.root)
  local request_id
  request_id = client:request("bash", { command = command }, function(success, data, err)
    if request_id and project.direct_bash_request_id == request_id then
      project.direct_bash_request_id = nil
    end
    if not request_id then
      if not success and project_is_current(project) then
        notify_error(err or "Unable to start Bash command")
      end
      return
    end
    if not project_is_current(project) then
      return
    end
    if not success then
      chat:end_tool(request_id, { content = { { type = "text", text = err or "Bash failed" } } }, true)
    else
      data = data or {}
      chat:end_bash(request_id, data, (data.exitCode or 0) ~= 0)
    end
  end, 0)
  if request_id and project_is_current(project) then
    project.direct_bash_request_id = request_id
    chat:start_tool(request_id, "bash", { command = command })
  end
end

local function stop(root)
  local client = clients[root]
  local project = projects[root]
  projects[root] = nil
  if client then
    clients[root] = nil
    if project and project.client == client and type(project.unsubscribe) == "function" then
      project.unsubscribe()
      project.unsubscribe = nil
    end
    dialog.discard(client)
    client:stop()
  end
  local chat = chats[root]
  if chat then
    chats[root] = nil
    chat:destroy()
  end
end

local function stop_all()
  local roots = {}
  for root in pairs(clients) do
    roots[root] = true
  end
  for root in pairs(chats) do
    roots[root] = true
  end
  for root in pairs(projects) do
    roots[root] = true
  end
  local ordered = vim.tbl_keys(roots)
  table.sort(ordered)
  for _, root in ipairs(ordered) do
    stop(root)
  end
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
M.abort = abort
M.run_bash = run_bash
M.stop = stop
M.stop_all = stop_all

return M
