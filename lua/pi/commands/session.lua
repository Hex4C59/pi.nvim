local runtime = require("pi.runtime")
local session_file = require("pi.session_file")
local chat_ui = require("pi.ui.chat")

local M = {}

local notify_error = runtime.notify_error
local text_content = chat_ui.text_content
local builtin_commands = chat_ui.builtin_commands

function M.new_session(root)
  local client = runtime.get_client(root)
  client:request("new_session", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif not data.cancelled then
      runtime.reload_session(client)
    end
  end)
end

function M.compact(instructions, root)
  local payload = {}
  if instructions and instructions ~= "" then
    payload.customInstructions = instructions
  end
  runtime.get_client(root):request("compact", payload, function(success, _, err)
    if not success then
      notify_error(err)
    end
  end, 0)
end

function M.status(root)
  local client = runtime.get_client(root)
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
    runtime.chat_for(client.root):update_stats(data)
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
  local client = runtime.get_client(root)
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
                runtime.reload_session(client)
                runtime.chat_for(client.root):set_input(result.text or "")
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
  local client = runtime.get_client(root)
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
          runtime.reload_session(client)
          runtime.chat_for(client.root):set_input(result.text or item.text)
        end
      end)
    end)
  end)
end

function M.clone(root)
  local client = runtime.get_client(root)
  client:request("clone", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif not data.cancelled then
      runtime.reload_session(client)
    end
  end)
end

function M.name_session(name, root)
  local client = runtime.get_client(root)
  local function apply(value)
    if not value or vim.trim(value) == "" then
      return
    end
    client:request("set_session_name", { name = vim.trim(value) }, function(success, _, err)
      if not success then
        notify_error(err)
      else
        runtime.refresh_state(client)
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
  runtime.get_client(root):request("export_html", payload, function(success, data, err)
    if not success then
      notify_error(err)
    else
      vim.notify("Exported Pi session to " .. data.path, vim.log.levels.INFO, { title = "Pi" })
    end
  end)
end

function M.resume(path, root)
  local client = runtime.get_client(root)
  local function switch(value)
    if not value or vim.trim(value) == "" then
      return
    end
    local header, header_err = session_file.read_header(value)
    if not header then
      notify_error(header_err)
      return
    end
    local same, roots = session_file.same_root(client.root, header.cwd)
    if not same then
      if type(roots) == "string" then
        notify_error(roots)
      else
        notify_error(
          ("Cross-project session resume is blocked. Current root: %s; session root: %s"):format(
            roots.current,
            roots.session
          )
        )
      end
      return
    end
    client:request("switch_session", { sessionPath = header.path }, function(success, data, err)
      if not success then
        notify_error(err)
      elseif data and not data.cancelled then
        runtime.reload_session(client)
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
  local client = runtime.get_client(root)
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
        runtime.chat_for(client.root):set_input("/" .. command.name .. " ")
      end
    end)
  end)
end

return M
