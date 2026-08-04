local runtime = require("pi.runtime")

local M = {}
local actions = setmetatable({}, { __mode = "k" })
local auth_flows = setmetatable({}, { __mode = "k" })

local function notify(message, level, title)
  vim.notify(message, level or vim.log.levels.INFO, { title = title or "Pi" })
end

local function notify_error(message)
  runtime.notify_error(message)
end

local function unavailable(command)
  notify(runtime.rpc_unavailable_commands[command], vim.log.levels.WARN, "Pi /" .. command)
end

local function with_capability(command, root, callback)
  local client = runtime.get_client(root)
  local function continue_with_state()
    if not runtime.client_is_current(client) then
      return
    end
    if runtime.has_capability(client, "administrative_workflows") then
      callback(client)
    else
      unavailable(command)
    end
  end
  if type(client.session.rpcCapabilities) == "table" then
    continue_with_state()
    return
  end
  client:request("get_state", {}, function(success, data, err)
    if not runtime.client_is_current(client) then
      return
    end
    if not success then
      notify_error(err or "Unable to inspect Pi RPC capabilities")
      return
    end
    client.session = data or {}
    runtime.chat_for(client.root):update_state(client.session)
    continue_with_state()
  end)
end

local function close_surface(surface)
  if surface and not surface.closed then
    surface:close()
  end
end

local function begin_action(client)
  local previous = actions[client]
  if previous then
    close_surface(previous.surface)
  end
  local action = { generation = (previous and previous.generation or 0) + 1 }
  actions[client] = action
  return action
end

local function action_current(client, action)
  return runtime.client_is_current(client) and actions[client] == action
end

local function bind_surface(client, action, surface)
  if action_current(client, action) then
    action.surface = surface
  else
    close_surface(surface)
  end
  return surface
end

local function request(client, action, command, payload, callback, timeout)
  client:request(command, payload or {}, function(success, data, err)
    if not action_current(client, action) then
      return
    end
    if not success then
      notify_error(err or ("Pi %s failed"):format(command))
      return
    end
    callback(data or {})
  end, timeout)
end

local function normalized_query(value)
  return vim.trim(value or ""):lower()
end

local function matching_providers(providers, query)
  query = normalized_query(query)
  if query == "" then
    return providers
  end
  local exact = {}
  local partial = {}
  for _, provider in ipairs(providers) do
    local id = tostring(provider.id or ""):lower()
    local name = tostring(provider.name or ""):lower()
    if id == query or name == query then
      table.insert(exact, provider)
    elseif id:find(query, 1, true) or name:find(query, 1, true) then
      table.insert(partial, provider)
    end
  end
  return #exact > 0 and exact or partial
end

local function choose_provider(client, action, providers, query, title, callback)
  providers = matching_providers(providers, query)
  if #providers == 0 then
    notify_error("No Pi provider matches: " .. vim.trim(query or ""))
  elseif #providers == 1 then
    callback(providers[1])
  else
    bind_surface(
      client,
      action,
      runtime.open_admin_select({
        title = title,
        items = providers,
        format_item = function(provider)
          return ("%s (%s)"):format(provider.name or provider.id, provider.id)
        end,
        on_select = function(provider)
          if provider and action_current(client, action) then
            callback(provider)
          end
        end,
      })
    )
  end
end

local function cancel_auth(client, flow)
  close_surface(flow.surface)
  flow.surface = nil
  client:request("cancel_auth", { flowId = flow.flow_id }, function(success, _, err)
    if runtime.client_is_current(client) and not success then
      auth_flows[client] = nil
      notify_error(err or "Unable to cancel authentication")
    end
  end)
end

local function open_auth_prompt(client, event)
  local flow = auth_flows[client]
  if not flow or (flow.flow_id and flow.flow_id ~= event.flowId) then
    return
  end
  flow.flow_id = event.flowId
  close_surface(flow.surface)
  flow.surface = nil
  flow.prompt_id = event.promptId

  local function submit(value)
    local current = auth_flows[client]
    if current ~= flow or not runtime.client_is_current(client) then
      return
    end
    flow.surface = nil
    flow.prompt_id = nil
    local payload = {
      flowId = event.flowId,
      promptId = event.promptId,
      value = value or "",
    }
    client:request("submit_auth_value", payload, function(success, _, err)
      if auth_flows[client] == flow and runtime.client_is_current(client) and not success then
        notify_error(err or "Authentication input was rejected")
        cancel_auth(client, flow)
      end
    end)
    payload.value = nil
    value = nil
  end
  local function cancel()
    if auth_flows[client] == flow and runtime.client_is_current(client) then
      cancel_auth(client, flow)
    end
  end

  if event.promptType == "select" then
    flow.surface = runtime.open_admin_select({
      title = event.message or "Pi authentication",
      items = event.options or {},
      format_item = function(option)
        local detail = option.description and option.description ~= "" and (" - " .. option.description) or ""
        return (option.label or option.id) .. detail
      end,
      on_select = function(option)
        if option then
          submit(option.id)
        else
          cancel()
        end
      end,
      on_cancel = cancel,
    })
  else
    flow.surface = runtime.open_admin_input({
      title = event.message or "Pi authentication",
      placeholder = event.placeholder,
      sensitive = event.sensitive == true,
      on_submit = submit,
      on_cancel = cancel,
    })
  end
end

local function auth_notice(event)
  if event.noticeType == "auth_url" then
    local lines = {}
    if event.instructions and event.instructions ~= "" then
      table.insert(lines, event.instructions)
    end
    table.insert(lines, event.url or "")
    notify(table.concat(lines, "\n"), vim.log.levels.INFO, "Pi authentication")
  elseif event.noticeType == "device_code" then
    notify(
      ("Open %s\nCode: %s"):format(event.verificationUri or "", event.userCode or ""),
      vim.log.levels.INFO,
      "Pi authentication"
    )
  elseif event.noticeType == "info" then
    local lines = { event.message or "" }
    for _, link in ipairs(event.links or {}) do
      table.insert(lines, ((link.label and link.label ~= "") and (link.label .. ": ") or "") .. (link.url or ""))
    end
    notify(table.concat(lines, "\n"), vim.log.levels.INFO, "Pi authentication")
  else
    notify(event.message or "Authentication in progress", vim.log.levels.INFO, "Pi authentication")
  end
end

function M.handle_event(client, event)
  if not runtime.client_is_current(client) then
    return
  end
  local flow = auth_flows[client]
  if not flow then
    return
  end
  if event.type == "auth_prompt" then
    open_auth_prompt(client, event)
  elseif event.type == "auth_prompt_cancel" then
    if (not flow.flow_id or flow.flow_id == event.flowId) and flow.prompt_id == event.promptId and flow.surface then
      close_surface(flow.surface)
      flow.surface = nil
      flow.prompt_id = nil
    end
  elseif event.type == "auth_notice" and (not flow.flow_id or flow.flow_id == event.flowId) then
    flow.flow_id = event.flowId
    auth_notice(event)
  elseif event.type == "auth_complete" and (not flow.flow_id or flow.flow_id == event.flowId) then
    close_surface(flow.surface)
    auth_flows[client] = nil
    if event.success then
      notify(
        "Authentication completed for " .. (event.provider or "provider"),
        vim.log.levels.INFO,
        "Pi authentication"
      )
      runtime.refresh_administrative_state(client)
    elseif event.cancelled then
      notify("Authentication cancelled", vim.log.levels.INFO, "Pi authentication")
    else
      notify_error(event.error or "Authentication failed")
    end
  end
end

function M.discard(client)
  local action = actions[client]
  if action then
    close_surface(action.surface)
    actions[client] = { generation = action.generation + 1 }
  end
  local flow = auth_flows[client]
  if flow then
    close_surface(flow.surface)
    auth_flows[client] = nil
  end
end

function M.login(root, query)
  with_capability("login", root, function(client)
    if auth_flows[client] then
      notify_error("An authentication flow is already active")
      return
    end
    local action = begin_action(client)
    request(client, action, "get_auth_providers", {}, function(data)
      local providers = {}
      for _, provider in ipairs(data.providers or {}) do
        local methods = {}
        for _, method in ipairs(provider.methods or {}) do
          if method.interactive then
            table.insert(methods, method)
          end
        end
        if #methods > 0 then
          local copy = vim.deepcopy(provider)
          copy.methods = methods
          table.insert(providers, copy)
        end
      end
      choose_provider(client, action, providers, query, "Pi login provider", function(provider)
        local function start(method)
          if not method or not action_current(client, action) then
            return
          end
          local flow = { flow_id = nil, surface = nil }
          auth_flows[client] = flow
          client:request("begin_auth", { provider = provider.id, method = method.type }, function(success, result, err)
            if auth_flows[client] ~= flow or not runtime.client_is_current(client) then
              return
            end
            if not success then
              auth_flows[client] = nil
              notify_error(err or "Unable to start authentication")
            else
              flow.flow_id = result and result.flowId or flow.flow_id
            end
          end)
        end
        if #provider.methods == 1 then
          start(provider.methods[1])
        else
          bind_surface(
            client,
            action,
            runtime.open_admin_select({
              title = "Pi authentication method",
              items = provider.methods,
              format_item = function(method)
                return method.name or method.type
              end,
              on_select = start,
            })
          )
        end
      end)
    end)
  end)
end

function M.logout(root, query)
  with_capability("logout", root, function(client)
    local action = begin_action(client)
    request(client, action, "get_auth_providers", {}, function(data)
      local providers = {}
      for _, provider in ipairs(data.providers or {}) do
        if provider.storedCredential then
          table.insert(providers, provider)
        end
      end
      if #providers == 0 then
        notify("Pi has no stored provider credentials to remove")
        return
      end
      choose_provider(client, action, providers, query, "Pi logout provider", function(provider)
        bind_surface(
          client,
          action,
          runtime.open_admin_confirm({
            title = "Remove provider credential",
            message = ("Remove Pi's stored credential for %s?"):format(provider.name or provider.id),
            on_confirm = function(confirmed)
              if not confirmed or not action_current(client, action) then
                return
              end
              request(client, action, "logout_provider", { provider = provider.id }, function()
                notify("Removed stored credential for " .. (provider.name or provider.id))
                runtime.refresh_administrative_state(client)
              end, 0)
            end,
          })
        )
      end)
    end)
  end)
end

local function trust_summary(data)
  local active = data.active and "trusted" or "untrusted"
  local saved = data.saved and data.saved.decision or "unset"
  return ("Active process: %s\nSaved decision: %s"):format(active, saved)
end

function M.trust(root)
  with_capability("trust", root, function(client)
    local action = begin_action(client)
    request(client, action, "get_project_trust", {}, function(data)
      local choices = {
        { decision = "trusted", label = "Trust this project" },
        { decision = "untrusted", label = "Do not trust this project" },
        { decision = "unset", label = "Remove the saved decision" },
      }
      bind_surface(
        client,
        action,
        runtime.open_admin_select({
          title = "Pi project trust - " .. (data.cwd or client.root),
          items = choices,
          format_item = function(choice)
            return choice.label
          end,
          on_select = function(choice)
            if not choice or not action_current(client, action) then
              return
            end
            request(client, action, "set_project_trust", { decision = choice.decision }, function(result)
              local restart = result.restartRequired and "\nRestart Pi to apply the saved decision." or ""
              notify(
                trust_summary(result) .. restart .. "\nPermission mode is unchanged.",
                vim.log.levels.INFO,
                "Pi trust"
              )
            end)
          end,
        })
      )
    end)
  end)
end

function M.reload(root)
  with_capability("reload", root, function(client)
    local action = begin_action(client)
    request(client, action, "reload_resources", {}, function(data)
      runtime.replace_extension_projection(client)
      local resources = data.resources or {}
      notify(
        ("Reloaded %d extensions, %d skills, %d prompts, and %d themes"):format(
          resources.extensions or 0,
          resources.skills or 0,
          resources.prompts or 0,
          resources.themes or 0
        ),
        vim.log.levels.INFO,
        "Pi reload"
      )
    end, 0)
  end)
end

function M.scoped_models(root)
  with_capability("scoped-models", root, function(client)
    local action = begin_action(client)
    request(client, action, "get_model_scope", {}, function(data)
      local available = data.available or {}
      local selected = data.allEnabled and available or (data.enabled or {})
      bind_surface(
        client,
        action,
        runtime.open_admin_multi_select({
          title = "Pi model cycling scope",
          items = available,
          selected = selected,
          on_empty = function()
            notify_error("Select at least one model for the cycling scope")
          end,
          on_select = function(models)
            if not action_current(client, action) then
              return
            end
            if #models == #available then
              models = {}
            end
            request(client, action, "set_model_scope", { models = models, persist = true }, function(result)
              runtime.refresh_administrative_state(client)
              local count = result.allEnabled and #(result.available or {}) or #(result.enabled or {})
              notify(("Model cycling scope now includes %d models"):format(count))
            end)
          end,
        })
      )
    end)
  end)
end

function M.import_session(root, path)
  with_capability("import", root, function(client)
    local action = begin_action(client)
    local function apply(value)
      if not action_current(client, action) or not value or vim.trim(value) == "" then
        return
      end
      request(client, action, "import_session", { path = vim.fn.expand(vim.trim(value)) }, function(data)
        if not data.cancelled then
          runtime.reload_session(client)
          runtime.refresh_commands(client)
        end
      end, 0)
    end
    if path and vim.trim(path) ~= "" then
      apply(path)
    else
      bind_surface(
        client,
        action,
        runtime.open_admin_input({
          title = "Import Pi session",
          placeholder = "/path/to/export.jsonl",
          on_submit = apply,
        })
      )
    end
  end)
end

function M.share(root)
  with_capability("share", root, function(client)
    local action = begin_action(client)
    bind_surface(
      client,
      action,
      runtime.open_admin_confirm({
        title = "Share Pi session",
        message = "Create a private GitHub gist containing the active session? This writes data outside Neovim.",
        on_confirm = function(confirmed)
          if not confirmed or not action_current(client, action) then
            return
          end
          request(client, action, "share_session", {}, function(data)
            notify(("Viewer: %s\nGist: %s"):format(data.url or "", data.gistUrl or ""), vim.log.levels.INFO, "Pi share")
          end, 0)
        end,
      })
    )
  end)
end

function M.changelog(root)
  with_capability("changelog", root, function(client)
    local action = begin_action(client)
    request(client, action, "get_changelog", { limit = 10 }, function(data)
      local lines = {}
      for _, entry in ipairs(data.entries or {}) do
        table.insert(lines, "# Pi " .. (entry.version or ""))
        vim.list_extend(lines, vim.split(entry.markdown or "", "\n", { plain = true }))
        table.insert(lines, "")
      end
      if #lines == 0 then
        lines = { "No changelog entries are available." }
      end
      bind_surface(client, action, runtime.show_admin_markdown({ title = "Pi changelog", lines = lines }))
    end)
  end)
end

return M
