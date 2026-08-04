local runtime = require("pi.runtime")
local session_file = require("pi.session_file")
local text_content = require("pi.message").text_content
local compact_count = require("pi.format").compact_count
local truncate_display = require("pi.format").truncate_display

local M = {}

local notify_error = runtime.notify_error

local function has_capability(client, name)
  for _, capability in ipairs((client.session and client.session.rpcCapabilities) or {}) do
    if capability == name then
      return true
    end
  end
  return false
end

local function action_current(client, action)
  return runtime.session_action_current(client, action)
end

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
    local context_window = tonumber(usage.contextWindow) and compact_count(usage.contextWindow) or "n/a"
    local auto_compaction = client.session and client.session.autoCompactionEnabled
    local auto_retry = client.session and client.session.autoRetryEnabled
    local cache_detail = compact_count(cache_read)
    if cache_hit then
      cache_detail = cache_detail .. (" (%.1f%% hit)"):format(cache_hit)
    end
    runtime.chat_for(client.root):update_stats(data)
    vim.notify(
      table.concat({
        "Session: " .. (data.sessionId or "ephemeral"),
        ("Messages: %d"):format(data.totalMessages or 0),
        ("Tools: %d"):format(data.toolCalls or 0),
        "Input tokens: " .. compact_count(input),
        "Output tokens: " .. compact_count(output),
        "Cache read: " .. cache_detail,
        ("Context: %s%% of %s"):format(usage.percent or "n/a", context_window),
        ("Cost: $%.4f"):format(data.cost or 0),
        "Auto-compact: " .. (auto_compaction == nil and "unknown" or auto_compaction and "on" or "off"),
        "Auto-retry: " .. (auto_retry == nil and "unknown" or auto_retry and "on" or "off"),
      }, "\n"),
      vim.log.levels.INFO,
      { title = "Pi" }
    )
  end)
end

local function entry_text(entry, width)
  local label
  if entry.type == "message" and entry.message then
    local role = entry.message.role or "message"
    local text = text_content(entry.message.content):gsub("%s+", " ")
    label = ("%s: %s"):format(role, text)
  elseif entry.type == "compaction" then
    label = "compaction"
  elseif entry.type == "branch_summary" then
    label = "branch summary"
  elseif entry.type == "model_change" then
    label = "model: " .. (entry.modelId or "")
  elseif entry.type == "thinking_level_change" then
    label = "thinking: " .. (entry.thinkingLevel or "")
  else
    label = entry.type or "entry"
  end
  return truncate_display(label, width)
end

local function flatten_tree(nodes, leaf_id, prefix, output)
  prefix = prefix or ""
  output = output or {}
  for index, node in ipairs(nodes or {}) do
    local last = index == #nodes
    local connector = last and "└─ " or "├─ "
    local active = node.entry.id == leaf_id and " ← active" or ""
    local row_width = math.max(8, math.min(80, vim.o.columns - 2))
    local fixed_width = vim.fn.strdisplaywidth(prefix .. connector .. active)
    local body_width = math.max(1, row_width - fixed_width)
    local label = prefix .. connector .. entry_text(node.entry, body_width) .. active
    table.insert(output, {
      node = node,
      label = truncate_display(label, row_width),
    })
    flatten_tree(node.children, leaf_id, prefix .. (last and "   " or "│  "), output)
  end
  return output
end

function M.tree(root)
  local client = runtime.get_client(root)
  local action_token = runtime.begin_session_action(client)
  local tree_surface = runtime.open_inline_select(client.root, {
    title = "Pi session tree",
    items = {},
    loading = true,
  })
  client:request("get_tree", {}, function(success, data, err)
    if not action_current(client, action_token) or tree_surface.closed then
      return
    end
    if not success then
      tree_surface:set_error(err)
      notify_error(err)
      return
    end
    local items = flatten_tree(data.tree, data.leafId)
    tree_surface = tree_surface:replace({
      title = "Pi session tree",
      items = items,
      keep_open = true,
      current_key = data.leafId,
      key_item = function(item)
        return item.node.entry.id
      end,
      format_item = function(item)
        return item.label
      end,
      on_select = function(item)
        if not item or not action_current(client, action_token) then
          return
        end
        local entry = item.node.entry
        local choices = {}
        if has_capability(client, "navigate_tree") and entry.id ~= data.leafId then
          table.insert(choices, { action = "navigate", label = "Navigate here" })
          table.insert(choices, { action = "navigate_summary", label = "Navigate here with summary" })
        end
        local user_message = entry.type == "message" and entry.message and entry.message.role == "user"
        if user_message then
          table.insert(choices, { action = "fork", label = "Fork from this message" })
          table.insert(choices, { action = "copy", label = "Copy message" })
        end
        if #choices == 0 then
          vim.notify(
            "The installed Pi RPC can inspect this node but does not advertise navigate_tree",
            vim.log.levels.INFO,
            { title = "Pi" }
          )
          return
        end
        tree_surface:push({
          title = "Tree action",
          items = choices,
          format_item = function(choice)
            return choice.label
          end,
          on_select = function(selected_action)
            if not selected_action or not action_current(client, action_token) then
              return
            end
            if selected_action.action == "navigate" or selected_action.action == "navigate_summary" then
              client:request("navigate_tree", {
                entryId = entry.id,
                summarize = selected_action.action == "navigate_summary",
              }, function(ok, result, navigate_err)
                if not action_current(client, action_token) then
                  return
                end
                if not ok then
                  notify_error(navigate_err)
                elseif not result.cancelled then
                  runtime.reload_session(client)
                  if result.editorText ~= nil then
                    runtime.chat_for(client.root):set_input(result.editorText)
                  end
                end
              end, 0)
            elseif selected_action.action == "fork" then
              client:request("fork", { entryId = entry.id }, function(ok, result, fork_err)
                if not action_current(client, action_token) then
                  return
                end
                if not ok then
                  notify_error(fork_err)
                elseif not result.cancelled then
                  runtime.reload_session(client)
                  runtime.chat_for(client.root):set_input(result.text or "")
                end
              end)
            elseif selected_action.action == "copy" then
              vim.fn.setreg("+", text_content(entry.message.content))
            end
          end,
        })
      end,
    })
  end)
end

function M.fork(root)
  local client = runtime.get_client(root)
  local action_token = runtime.begin_session_action(client)
  local fork_surface = runtime.open_inline_select(client.root, {
    title = "Fork Pi session",
    items = {},
    loading = true,
  })
  client:request("get_fork_messages", {}, function(success, data, err)
    if not action_current(client, action_token) or fork_surface.closed then
      return
    end
    if not success then
      fork_surface:set_error(err)
      notify_error(err)
      return
    end
    fork_surface:replace({
      title = "Fork Pi session",
      items = data.messages or {},
      key_item = function(item)
        return item.entryId
      end,
      format_item = function(item)
        return item.text:gsub("%s+", " ")
      end,
      on_select = function(item)
        if not item or not action_current(client, action_token) then
          return
        end
        client:request("fork", { entryId = item.entryId }, function(ok, result, fork_err)
          if not action_current(client, action_token) then
            return
          elseif not ok then
            notify_error(fork_err)
          elseif not result.cancelled then
            runtime.reload_session(client)
            runtime.chat_for(client.root):set_input(result.text or item.text)
          end
        end)
      end,
    })
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
    local chat = runtime.chat_for(client.root)
    chat:open(true)
    chat:set_input("/name " .. (client.session.sessionName or ""))
  end
end

function M.resume(path, root)
  local client = runtime.get_client(root)
  local action_token = runtime.begin_session_action(client)
  local function switch_path(value)
    if not action_current(client, action_token) then
      return
    end
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
      if not action_current(client, action_token) then
        return
      end
      if not success then
        notify_error(err)
      elseif data and not data.cancelled then
        runtime.reload_session(client)
      end
    end)
  end
  local function prompt_for_path()
    if not action_current(client, action_token) then
      return
    end
    local chat = runtime.chat_for(client.root)
    chat:open(true)
    chat:set_input("/resume ")
  end
  if path and vim.trim(path) ~= "" then
    switch_path(path)
    return
  end
  if not has_capability(client, "list_sessions") then
    vim.notify(
      "The installed Pi RPC does not advertise list_sessions; enter an exact session path instead",
      vim.log.levels.INFO,
      { title = "Pi" }
    )
    prompt_for_path()
    return
  end

  local function load_more(cursor, active_picker)
    if not action_current(client, action_token) or active_picker.closed then
      return
    end
    client:request("list_sessions", { limit = 50, cursor = cursor }, function(success, data, err)
      if not action_current(client, action_token) or active_picker.closed then
        return
      end
      if success then
        active_picker:append(data.sessions or {}, data.nextCursor)
      else
        active_picker:set_error(err)
        notify_error(err)
      end
    end)
  end
  local function load_catalog(active_surface)
    client:request("list_sessions", { limit = 50 }, function(success, data, err)
      if not action_current(client, action_token) or active_surface.closed then
        return
      end
      if not success then
        active_surface:set_error(err)
        notify_error(err)
        return
      end
      active_surface:close()
      runtime.open_session_picker({
        root = client.root,
        sessions = data.sessions or {},
        next_cursor = data.nextCursor,
        on_more = load_more,
        on_path = prompt_for_path,
        on_select = function(session)
          if not action_current(client, action_token) then
            return
          end
          if type(session.path) ~= "string" or type(session.cwd) ~= "string" then
            notify_error("Pi returned incomplete session metadata")
            return
          end
          local same, roots = session_file.same_root(client.root, session.cwd)
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
          client:request("switch_session", { sessionPath = session.path }, function(ok, result, switch_err)
            if not action_current(client, action_token) then
              return
            end
            if not ok then
              notify_error(switch_err)
            elseif result and not result.cancelled then
              runtime.reload_session(client)
            end
          end)
        end,
      })
    end)
  end
  local resume_surface = runtime.open_inline_select(client.root, {
    title = "Pi sessions",
    items = {},
    loading = true,
    on_more = function(_, active_surface)
      load_catalog(active_surface)
    end,
  })
  load_catalog(resume_surface)
end

return M
