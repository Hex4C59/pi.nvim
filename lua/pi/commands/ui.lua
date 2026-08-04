local runtime = require("pi.runtime")
local model_cmds = require("pi.commands.model")
local permission_cmds = require("pi.commands.permission")

local M = {}

local notify_error = runtime.notify_error

local function enabled_label(value)
  if type(value) ~= "boolean" then
    return "unknown"
  end
  return value and "on" or "off"
end

local function set_auto_retry(client, enabled)
  client:request("set_auto_retry", { enabled = enabled }, function(ok, _, err)
    if not ok then
      notify_error(err)
    else
      runtime.refresh_state(client)
    end
  end)
end

function M.layout(position, root, options)
  root = root or runtime.client_root()
  local chat = runtime.chat_for(root)
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
  if position ~= "" and vim.tbl_contains(choices, position) then
    apply(position)
  else
    local matches = choices
    if position ~= "" then
      matches = {}
      local query = position:lower()
      for _, choice in ipairs(choices) do
        if choice:lower():find(query, 1, true) then
          table.insert(matches, choice)
        end
      end
      if #matches == 0 then
        notify_error("Unknown Pi layout: " .. position)
        return
      elseif #matches == 1 then
        apply(matches[1])
        return
      end
    end
    runtime.open_inline_select(root, {
      title = position ~= "" and ("Pi layout - " .. position) or "Pi layout",
      items = matches,
      current = chat:current_layout(),
      stack = type(options) == "table" and options.stack or nil,
      on_select = apply,
    })
  end
end

function M.settings(root)
  local client = runtime.get_client(root)
  local state = client.session or {}
  local chat = runtime.chat_for(client.root)
  local display_state = chat:display_state()
  local options = {
    { label = "Model", value = state.model and state.model.id or "unknown", action = "model" },
    { label = "Thinking level", value = state.thinkingLevel or "off", action = "thinking" },
    { label = "Permission mode", value = display_state.permission_mode_label, action = "permissions" },
    { label = "Auto-compact", value = state.autoCompactionEnabled and "on" or "off", action = "compact" },
    { label = "Auto-retry", value = enabled_label(state.autoRetryEnabled), action = "retry" },
    { label = "Steering mode", value = state.steeringMode or "one-at-a-time", action = "steering" },
    { label = "Follow-up mode", value = state.followUpMode or "one-at-a-time", action = "followup" },
    { label = "Workspace layout", value = display_state.layout, action = "layout" },
    {
      label = "Transcript detail",
      value = display_state.process_expanded and "detailed" or "compact",
      action = "details",
    },
  }
  local settings_surface
  local function close_settings()
    if settings_surface and not settings_surface.closed then
      settings_surface:close()
    end
  end
  settings_surface = runtime.open_inline_select(client.root, {
    title = "Pi settings",
    items = options,
    keep_open = true,
    format_item = function(item)
      return item.label
    end,
    describe_item = function(item)
      return item.value
    end,
    on_select = function(item)
      if not item then
        return
      elseif item.action == "model" then
        model_cmds.select_model(client.root, nil, { stack = "push" })
      elseif item.action == "thinking" then
        model_cmds.select_thinking_level(client.root, nil, { stack = "push" })
      elseif item.action == "permissions" then
        permission_cmds.select(client.root, nil, { stack = "push" })
      elseif item.action == "compact" then
        close_settings()
        local enabled = not state.autoCompactionEnabled
        client:request("set_auto_compaction", { enabled = enabled }, function(ok, _, err)
          if not ok then
            notify_error(err)
          else
            runtime.refresh_state(client)
          end
        end)
      elseif item.action == "retry" then
        if type(state.autoRetryEnabled) == "boolean" then
          close_settings()
          set_auto_retry(client, not state.autoRetryEnabled)
        else
          local choices = {
            { label = "Enable", enabled = true },
            { label = "Disable", enabled = false },
          }
          runtime.open_inline_select(client.root, {
            title = "Set Pi auto-retry",
            items = choices,
            stack = "push",
            format_item = function(choice)
              return choice.label
            end,
            on_select = function(choice)
              if choice then
                set_auto_retry(client, choice.enabled)
              end
            end,
          })
        end
      elseif item.action == "steering" then
        close_settings()
        local mode = state.steeringMode == "all" and "one-at-a-time" or "all"
        client:request("set_steering_mode", { mode = mode }, function(ok, _, err)
          if not ok then
            notify_error(err)
          else
            runtime.refresh_state(client)
          end
        end)
      elseif item.action == "followup" then
        close_settings()
        local mode = state.followUpMode == "all" and "one-at-a-time" or "all"
        client:request("set_follow_up_mode", { mode = mode }, function(ok, _, err)
          if not ok then
            notify_error(err)
          else
            runtime.refresh_state(client)
          end
        end)
      elseif item.action == "layout" then
        M.layout(nil, client.root, { stack = "push" })
      elseif item.action == "details" then
        close_settings()
        chat:toggle_process()
      end
    end,
  })
end

function M.hotkeys()
  vim.notify(
    table.concat({
      "Enter          submit",
      "Ctrl-J         new line",
      "Esc            close completion or interrupt",
      "Ctrl-C         interrupt",
      "Ctrl-Q         return to editor",
      "Alt-Enter      queue follow-up",
      "Ctrl-L         prefill /model",
      "Ctrl-P         prefill /model",
      "Alt-P          prefill /permissions",
      "Shift-Tab      prefill /thinking",
      "Ctrl-O         toggle process details",
      "Ctrl-T         toggle process details",
      "Left-drag      copy transcript selection",
      "Right-click    paste into prompt",
      "/               open command completion",
      "/permissions    select permission mode",
      "Tab / Shift-Tab select command",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "Pi hotkeys" }
  )
end

return M
