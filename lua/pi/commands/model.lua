local runtime = require("pi.runtime")
local compact_count = require("pi.format").compact_count

local M = {}

local notify_error = runtime.notify_error

local function menu_stack(options)
  return type(options) == "table" and options.stack or nil
end

local function chat_generation(root)
  return type(runtime.chat_action_generation) == "function" and runtime.chat_action_generation(root) or nil
end

function M.select_model(root, query, options)
  local client = runtime.get_client(root)
  local action_generation = chat_generation(client.root)
  local function action_current()
    return runtime.client_is_current(client)
      and (action_generation == nil or chat_generation(client.root) == action_generation)
  end
  query = vim.trim(query or "")
  local loading
  if query == "" then
    loading = runtime.open_inline_select(client.root, {
      title = "Pi model",
      items = {},
      loading = true,
      stack = menu_stack(options),
    })
  end
  client:request("get_available_models", {}, function(success, data, err)
    if not action_current() or (loading and loading.closed) then
      return
    end
    if not success then
      if loading then
        loading:set_error(err)
      end
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
        if not runtime.client_is_current(client) then
          return
        end
        if not ok then
          notify_error(set_err)
        else
          runtime.refresh_state(client)
        end
      end)
    end

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

    local menu = {
      title = query ~= "" and ("Pi model - " .. query) or "Pi model",
      items = models,
      current = current,
      key_item = function(model)
        return model.provider .. "\0" .. model.id
      end,
      format_item = function(model)
        return ("%s/%s"):format(model.provider, model.id)
      end,
      describe_item = function(model)
        return model.contextWindow and ("%s context"):format(compact_count(model.contextWindow)) or ""
      end,
      on_select = apply,
      stack = menu_stack(options),
    }
    if loading then
      loading:replace(menu)
    else
      runtime.open_inline_select(client.root, menu)
    end
  end)
end

function M.select_thinking_level(root, requested, options)
  local client = runtime.get_client(root)
  local action_generation = chat_generation(client.root)
  local function action_current()
    return runtime.client_is_current(client)
      and (action_generation == nil or chat_generation(client.root) == action_generation)
  end
  requested = vim.trim(requested or "")
  local loading
  if requested == "" then
    loading = runtime.open_inline_select(client.root, {
      title = "Pi thinking level",
      items = {},
      loading = true,
      stack = menu_stack(options),
    })
  end
  client:request("get_available_thinking_levels", {}, function(success, data, err)
    if not action_current() or (loading and loading.closed) then
      return
    end
    if not success then
      if loading then
        loading:set_error(err)
      end
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
        if not runtime.client_is_current(client) then
          return
        end
        if not ok then
          notify_error(set_err)
        else
          runtime.refresh_state(client)
        end
      end)
    end

    if requested ~= "" then
      local exact = {}
      local partial = {}
      local normalized = requested:lower()
      for _, level in ipairs(levels) do
        if level:lower() == normalized then
          table.insert(exact, level)
        elseif level:lower():find(normalized, 1, true) then
          table.insert(partial, level)
        end
      end
      levels = #exact > 0 and exact or partial
      if #levels == 0 then
        notify_error("Unsupported Pi thinking level: " .. requested)
      elseif #levels == 1 then
        apply(levels[1])
      else
        runtime.open_inline_select(client.root, {
          title = "Pi thinking level - " .. requested,
          items = levels,
          current = current,
          on_select = apply,
          stack = menu_stack(options),
        })
      end
      return
    end

    loading:replace({
      title = "Pi thinking level",
      items = levels,
      current = current,
      on_select = apply,
    })
  end)
end

function M.cycle_model(root)
  local client = runtime.get_client(root)
  client:request("cycle_model", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif data and data.model then
      client.session.model = data.model
      client.session.thinkingLevel = data.thinkingLevel
      runtime.chat_for(client.root):update_state({
        model = data.model,
        thinkingLevel = data.thinkingLevel,
        autoCompactionEnabled = client.session.autoCompactionEnabled,
      })
    end
  end)
end

function M.cycle_thinking_level(root)
  local client = runtime.get_client(root)
  client:request("cycle_thinking_level", {}, function(success, data, err)
    if not success then
      notify_error(err)
    elseif data and data.level then
      client.session.thinkingLevel = data.level
      runtime.chat_for(client.root):update_state({
        model = client.session.model,
        thinkingLevel = data.level,
        autoCompactionEnabled = client.session.autoCompactionEnabled,
      })
    end
  end)
end

return M
