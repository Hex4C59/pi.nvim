local config = require("pi.config")
local Client = require("pi.client").Client
local context = require("pi.context")
local chat_ui = require("pi.ui.chat")
local Chat = chat_ui.Chat
local text_content = chat_ui.text_content
local builtin_commands = chat_ui.builtin_commands
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

function M.setup(opts)
  config.setup(opts)
end

function M.chat()
  local path = vim.api.nvim_buf_get_name(0)
  local client = get_client()
  local chat = chat_for(client.root)
  chat:set_path(path)
  chat:open()
end

function M.submit(text, root, behavior)
  text = vim.trim(text or "")
  if text == "" then
    return
  end
  root = root or client_root()
  local command, arguments = text:match("^/([%w:_-]+)%s*(.*)$")
  if command == "model" then
    M.select_model(root, arguments)
  elseif command == "thinking" then
    M.select_thinking_level(root, arguments)
  elseif command == "settings" then
    M.settings(root)
  elseif command == "layout" then
    M.layout(arguments, root)
  elseif command == "new" then
    M.new_session(root)
  elseif command == "compact" then
    M.compact(arguments, root)
  elseif command == "session" then
    M.status(root)
  elseif command == "tree" then
    M.tree(root)
  elseif command == "fork" then
    M.fork(root)
  elseif command == "clone" then
    M.clone(root)
  elseif command == "name" then
    M.name_session(arguments, root)
  elseif command == "export" then
    M.export_session(arguments, root)
  elseif command == "resume" then
    M.resume(arguments, root)
  elseif command == "copy" then
    M.copy_last_response(root)
  elseif command == "commands" then
    M.commands(root)
  elseif command == "hotkeys" then
    M.hotkeys()
  elseif command == "abort" then
    M.abort(root)
  elseif command == "clear" then
    M.new_session(root)
  elseif command == "quit" then
    chat_for(root):close()
  elseif command and rpc_unavailable_commands[command] then
    vim.notify(rpc_unavailable_commands[command], vim.log.levels.WARN, { title = "Pi /" .. command })
  elseif text:sub(1, 1) == "!" then
    M.bash(text:sub(text:sub(1, 2) == "!!" and 3 or 2), root)
  else
    send_prompt(text, nil, root, behavior)
  end
end

function M.layout(position, root)
  root = root or client_root()
  local chat = chat_for(root)
  local choices = { "tab", "float", "right", "bottom" }
  local function apply(value)
    if not value or value == "" then
      return
    end
    if not vim.tbl_contains(choices, value) then
      notify_error("Unknown Pi layout: " .. value)
      return
    end
    local was_open = chat:is_open()
    chat:set_position(value)
    if not was_open then
      chat:open()
    end
  end
  position = vim.trim(position or "")
  if position ~= "" then
    apply(position)
  else
    vim.ui.select(choices, { prompt = "Pi layout" }, apply)
  end
end

function M.ask(text, root)
  if not root then
    local path = vim.api.nvim_buf_get_name(0)
    root = client_root()
    chat_for(root):set_path(path)
  end
  with_prompt(text, function(prompt)
    send_prompt(prompt, nil, root)
  end)
end

function M.visual(text, first_line, last_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = client_root()
  chat_for(root):set_path(vim.api.nvim_buf_get_name(bufnr))
  local selected = context.range(bufnr, root, first_line, last_line, config.get().context)
  with_prompt(text, function(prompt)
    send_prompt(
      selected .. "\n\nUser request:\n" .. prompt,
      prompt
        .. (" [%s:%d-%d]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"), first_line, last_line)
    )
  end)
end

function M.buffer(text)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = client_root()
  chat_for(root):set_path(vim.api.nvim_buf_get_name(bufnr))
  local buffer_context = context.buffer(bufnr, root, config.get().context)
  with_prompt(text, function(prompt)
    send_prompt(
      buffer_context .. "\n\nUser request:\n" .. prompt,
      prompt .. (" [%s]"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"))
    )
  end)
end

function M.abort(root)
  local client = get_client(root)
  local command = client.bash_running and "abort_bash" or "abort"
  client:request(command, {}, function(success, _, err)
    if not success then
      notify_error(err)
    end
  end)
end

function M.select_model(root, query)
  local client = get_client(root)
  client:request("get_available_models", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    local current = client.session.model or {}
    local models = data.models or {}
    local function apply(model)
      if not model then
        return
      end
      client:request("set_model", { provider = model.provider, modelId = model.id }, function(ok, _, set_err)
        if not ok then
          notify_error(set_err)
        else
          refresh_state(client)
        end
      end)
    end

    query = vim.trim(query or "")
    if query ~= "" then
      local exact = {}
      local partial = {}
      local normalized = query:lower()
      for _, model in ipairs(models) do
        local reference = (model.provider .. "/" .. model.id):lower()
        local model_id = model.id:lower()
        if reference == normalized or model_id == normalized then
          table.insert(exact, model)
        elseif reference:find(normalized, 1, true) or model_id:find(normalized, 1, true) then
          table.insert(partial, model)
        end
      end
      models = #exact > 0 and exact or partial
      if #models == 0 then
        notify_error("No Pi model matches: " .. query)
        return
      elseif #models == 1 then
        apply(models[1])
        return
      end
    end

    vim.ui.select(models, {
      prompt = query ~= "" and ("Pi model · " .. query) or "Pi model",
      format_item = function(model)
        local marker = model.provider == current.provider and model.id == current.id and "●" or " "
        local context_window = model.contextWindow
            and ("  %s context"):format(chat_ui.format_count(model.contextWindow))
          or ""
        return ("%s %s/%s%s"):format(marker, model.provider, model.id, context_window)
      end,
    }, apply)
  end)
end

function M.select_thinking_level(root, requested)
  local client = get_client(root)
  client:request("get_available_thinking_levels", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    local current = client.session.thinkingLevel or "off"
    local levels = data.levels or { "off" }
    local function apply(level)
      if not level then
        return
      end
      client:request("set_thinking_level", { level = level }, function(ok, _, set_err)
        if not ok then
          notify_error(set_err)
        else
          refresh_state(client)
        end
      end)
    end

    requested = vim.trim(requested or "")
    if requested ~= "" then
      if not vim.tbl_contains(levels, requested) then
        notify_error("Unsupported Pi thinking level: " .. requested)
      else
        apply(requested)
      end
      return
    end

    vim.ui.select(levels, {
      prompt = "Pi thinking level",
      format_item = function(level)
        return (level == current and "● " or "  ") .. level
      end,
    }, apply)
  end)
end

function M.copy_last_response(root)
  chat_for(root or client_root()):copy_last_assistant()
end

function M.cycle_model(root)
  local client = get_client(root)
  client:request("cycle_model", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif data and data.model then
      client.session.model = data.model
      client.session.thinkingLevel = data.thinkingLevel
      chat_for(client.root):update_state({
        model = data.model,
        thinkingLevel = data.thinkingLevel,
        autoCompactionEnabled = client.session.autoCompactionEnabled,
      })
    end
  end)
end

function M.cycle_thinking_level(root)
  local client = get_client(root)
  client:request("cycle_thinking_level", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif data and data.level then
      client.session.thinkingLevel = data.level
      chat_for(client.root):update_state({
        model = client.session.model,
        thinkingLevel = data.level,
        autoCompactionEnabled = client.session.autoCompactionEnabled,
      })
    end
  end)
end

function M.settings(root)
  local client = get_client(root)
  local state = client.session or {}
  local chat = chat_for(client.root)
  local options = {
    { label = "Model", value = state.model and state.model.id or "unknown", action = "model" },
    { label = "Thinking level", value = state.thinkingLevel or "off", action = "thinking" },
    { label = "Auto-compact", value = state.autoCompactionEnabled and "on" or "off", action = "compact" },
    { label = "Steering mode", value = state.steeringMode or "one-at-a-time", action = "steering" },
    { label = "Follow-up mode", value = state.followUpMode or "one-at-a-time", action = "followup" },
    { label = "Workspace layout", value = chat.position or config.get().chat.position, action = "layout" },
    {
      label = "Transcript detail",
      value = chat.process_expanded and "detailed" or "compact",
      action = "details",
    },
  }
  vim.ui.select(options, {
    prompt = "Pi settings",
    format_item = function(item)
      return ("%-18s %s"):format(item.label, item.value)
    end,
  }, function(item)
    if not item then
      return
    elseif item.action == "model" then
      M.select_model(client.root)
    elseif item.action == "thinking" then
      M.select_thinking_level(client.root)
    elseif item.action == "compact" then
      local enabled = not state.autoCompactionEnabled
      client:request("set_auto_compaction", { enabled = enabled }, function(ok, _, err)
        if not ok then
          notify_error(err)
        else
          state.autoCompactionEnabled = enabled
          chat:update_state(state)
        end
      end)
    elseif item.action == "steering" then
      local mode = state.steeringMode == "all" and "one-at-a-time" or "all"
      client:request("set_steering_mode", { mode = mode }, function(ok, _, err)
        if not ok then
          notify_error(err)
        else
          state.steeringMode = mode
        end
      end)
    elseif item.action == "followup" then
      local mode = state.followUpMode == "all" and "one-at-a-time" or "all"
      client:request("set_follow_up_mode", { mode = mode }, function(ok, _, err)
        if not ok then
          notify_error(err)
        else
          state.followUpMode = mode
        end
      end)
    elseif item.action == "layout" then
      M.layout(nil, client.root)
    elseif item.action == "details" then
      chat:toggle_process()
    end
  end)
end

function M.new_session(root)
  local client = get_client(root)
  client:request("new_session", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif not data.cancelled then
      reload_session(client)
    end
  end)
end

function M.compact(instructions, root)
  local payload = {}
  if instructions and instructions ~= "" then
    payload.customInstructions = instructions
  end
  get_client(root):request("compact", payload, function(success, _, err)
    if not success then
      notify_error(err)
    end
  end, 0)
end

function M.status(root)
  local client = get_client(root)
  client:request("get_session_stats", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    local usage = data.contextUsage or {}
    local tokens = data.tokens or {}
    local input = tonumber(tokens.input) or 0
    local output = tonumber(tokens.output) or 0
    local cache_read = tonumber(tokens.cacheRead) or 0
    local cache_hit = input + cache_read > 0 and (cache_read / (input + cache_read) * 100) or nil
    local context_window = tonumber(usage.contextWindow) and chat_ui.format_count(usage.contextWindow) or "n/a"
    local auto_compaction = client.session and client.session.autoCompactionEnabled
    local cache_detail = chat_ui.format_count(cache_read)
    if cache_hit then
      cache_detail = cache_detail .. (" (%.1f%% hit)"):format(cache_hit)
    end
    chat_for(client.root):update_stats(data)
    vim.notify(
      table.concat({
        "Session: " .. (data.sessionId or "ephemeral"),
        ("Messages: %d"):format(data.totalMessages or 0),
        ("Tools: %d"):format(data.toolCalls or 0),
        "Input tokens: " .. chat_ui.format_count(input),
        "Output tokens: " .. chat_ui.format_count(output),
        "Cache read: " .. cache_detail,
        ("Context: %s%% of %s"):format(usage.percent or "n/a", context_window),
        ("Cost: $%.4f"):format(data.cost or 0),
        "Auto-compact: " .. (auto_compaction == nil and "unknown" or auto_compaction and "on" or "off"),
      }, "\n"),
      vim.log.levels.INFO,
      { title = "Pi" }
    )
  end)
end

local function entry_text(entry)
  if entry.type == "message" and entry.message then
    local role = entry.message.role or "message"
    local text = text_content(entry.message.content):gsub("%s+", " ")
    if #text > 80 then
      text = text:sub(1, 77) .. "..."
    end
    return ("%s: %s"):format(role, text)
  elseif entry.type == "compaction" then
    return "compaction"
  elseif entry.type == "branch_summary" then
    return "branch summary"
  elseif entry.type == "model_change" then
    return "model: " .. (entry.modelId or "")
  elseif entry.type == "thinking_level_change" then
    return "thinking: " .. (entry.thinkingLevel or "")
  end
  return entry.type or "entry"
end

local function flatten_tree(nodes, leaf_id, prefix, output)
  prefix = prefix or ""
  output = output or {}
  for index, node in ipairs(nodes or {}) do
    local last = index == #nodes
    local connector = last and "└─ " or "├─ "
    local active = node.entry.id == leaf_id and " ← active" or ""
    table.insert(output, {
      node = node,
      label = prefix .. connector .. entry_text(node.entry) .. active,
    })
    flatten_tree(node.children, leaf_id, prefix .. (last and "   " or "│  "), output)
  end
  return output
end

function M.tree(root)
  local client = get_client(root)
  client:request("get_tree", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    local items = flatten_tree(data.tree, data.leafId)
    vim.ui.select(items, {
      prompt = "Pi session tree",
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if not item then
        return
      end
      local entry = item.node.entry
      if entry.type == "message" and entry.message and entry.message.role == "user" then
        vim.ui.select({ "Fork from this message", "Copy message" }, { prompt = "Tree action" }, function(action)
          if action == "Fork from this message" then
            client:request("fork", { entryId = entry.id }, function(ok, result, fork_err)
              if not ok then
                notify_error(fork_err)
              elseif not result.cancelled then
                reload_session(client)
                chat_for(client.root):set_input(result.text or "")
              end
            end)
          elseif action == "Copy message" then
            vim.fn.setreg("+", text_content(entry.message.content))
          end
        end)
      else
        vim.notify(
          "Pi RPC can inspect this node but cannot move the active leaf to it",
          vim.log.levels.INFO,
          { title = "Pi" }
        )
      end
    end)
  end)
end

function M.fork(root)
  local client = get_client(root)
  client:request("get_fork_messages", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    vim.ui.select(data.messages or {}, {
      prompt = "Fork Pi session",
      format_item = function(item)
        return item.text:gsub("%s+", " ")
      end,
    }, function(item)
      if not item then
        return
      end
      client:request("fork", { entryId = item.entryId }, function(ok, result, fork_err)
        if not ok then
          notify_error(fork_err)
        elseif not result.cancelled then
          reload_session(client)
          chat_for(client.root):set_input(result.text or item.text)
        end
      end)
    end)
  end)
end

function M.clone(root)
  local client = get_client(root)
  client:request("clone", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif not data.cancelled then
      reload_session(client)
    end
  end)
end

function M.name_session(name, root)
  local client = get_client(root)
  local function apply(value)
    if not value or vim.trim(value) == "" then
      return
    end
    client:request("set_session_name", { name = vim.trim(value) }, function(success, _, err)
      if not success then
        notify_error(err)
      else
        refresh_state(client)
      end
    end)
  end
  if name and vim.trim(name) ~= "" then
    apply(name)
  else
    vim.ui.input({ prompt = "Pi session name: ", default = client.session.sessionName or "" }, apply)
  end
end

function M.export_session(path, root)
  local payload = {}
  if path and vim.trim(path) ~= "" then
    payload.outputPath = vim.fn.expand(vim.trim(path))
  end
  get_client(root):request("export_html", payload, function(success, data, err)
    if not success then
      notify_error(err)
    else
      vim.notify("Exported Pi session to " .. data.path, vim.log.levels.INFO, { title = "Pi" })
    end
  end)
end

function M.resume(path, root)
  local client = get_client(root)
  local function switch(value)
    if not value or vim.trim(value) == "" then
      return
    end
    client:request("switch_session", { sessionPath = vim.fn.expand(vim.trim(value)) }, function(success, data, err)
      if not success then
        notify_error(err)
      elseif not data.cancelled then
        reload_session(client)
      end
    end)
  end
  if path and vim.trim(path) ~= "" then
    switch(path)
  else
    vim.ui.input({ prompt = "Pi session file: " }, switch)
  end
end

function M.commands(root)
  local client = get_client(root)
  client:request("get_commands", {}, function(success, data, err)
    if not success then
      notify_error(err)
      return
    end
    local commands = {}
    local seen = {}
    for _, command in ipairs(builtin_commands) do
      table.insert(commands, command)
      seen[command.name] = true
    end
    for _, command in ipairs(data.commands or {}) do
      if not seen[command.name] then
        table.insert(commands, command)
      end
    end
    vim.ui.select(commands, {
      prompt = "Pi commands",
      format_item = function(command)
        local hint = command.argument_hint and (" " .. command.argument_hint) or ""
        local availability = command.tui_only and "  [Pi TUI only]" or ""
        return ("/%-32s %s%s"):format(command.name .. hint, command.description or "", availability)
      end,
    }, function(command)
      if command then
        chat_for(client.root):set_input("/" .. command.name .. " ")
      end
    end)
  end)
end

function M.hotkeys()
  vim.notify(
    table.concat({
      "Enter          submit",
      "Ctrl-J         new line",
      "Esc / Ctrl-C   interrupt",
      "Alt-Enter      queue follow-up",
      "Ctrl-L         select model",
      "Ctrl-P         cycle model",
      "Shift-Tab      cycle thinking",
      "Ctrl-O         toggle process details",
      "Ctrl-T         toggle process details",
      "Ctrl-X         copy last response",
      "/               open command completion",
      "Tab / Shift-Tab select command",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "Pi hotkeys" }
  )
end

function M.bash(command, root)
  command = vim.trim(command or "")
  if command == "" then
    return
  end
  local client = get_client(root)
  local chat = chat_for(client.root)
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

function M.track_buffer(bufnr)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  path = vim.fs.normalize(path)
  for root, chat in pairs(chats) do
    if context.is_within_root(root, path) then
      chat:set_path(path)
    end
  end
end

function M.stop()
  local root = client_root()
  if clients[root] then
    clients[root]:stop()
    clients[root] = nil
    if chats[root] then
      chats[root].history_loaded = false
      chats[root]:set_activity("stopped")
    end
  end
end

function M.stop_all()
  for root, client in pairs(clients) do
    client:stop()
    clients[root] = nil
    if chats[root] then
      chats[root].history_loaded = false
      chats[root]:set_activity("stopped")
    end
  end
end

return M
