local runtime = require("pi.runtime")
local compact_count = require("pi.format").compact_count

local M = {}

local notify_error = runtime.notify_error

function M.select_model(root, query)
  local client = runtime.get_client(root)
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
          runtime.refresh_state(client)
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
        local context_window = model.contextWindow and ("  %s context"):format(compact_count(model.contextWindow)) or ""
        return ("%s %s/%s%s"):format(marker, model.provider, model.id, context_window)
      end,
    }, apply)
  end)
end

function M.select_thinking_level(root, requested)
  local client = runtime.get_client(root)
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
          runtime.refresh_state(client)
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
