local config = require("pi.config")
local runtime = require("pi.runtime")
local model_cmds = require("pi.commands.model")
local permission_cmds = require("pi.commands.permission")

local M = {}

local notify_error = runtime.notify_error

function M.layout(position, root)
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
  if position ~= "" then
    apply(position)
  else
    vim.ui.select(choices, { prompt = "Pi layout" }, apply)
  end
end

function M.settings(root)
  local client = runtime.get_client(root)
  local state = client.session or {}
  local chat = runtime.chat_for(client.root)
  local options = {
    { label = "Model", value = state.model and state.model.id or "unknown", action = "model" },
    { label = "Thinking level", value = state.thinkingLevel or "off", action = "thinking" },
    { label = "Permission mode", value = chat:permission_mode_label(), action = "permissions" },
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
      model_cmds.select_model(client.root)
    elseif item.action == "thinking" then
      model_cmds.select_thinking_level(client.root)
    elseif item.action == "permissions" then
      permission_cmds.select(client.root)
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

function M.hotkeys()
  vim.notify(
    table.concat({
      "Enter          submit",
      "Ctrl-J         new line",
      "Esc / Ctrl-C   interrupt",
      "Alt-Enter      queue follow-up",
      "Ctrl-L         select model",
      "Ctrl-P         cycle model",
      "Alt-P          cycle permission mode",
      "Shift-Tab      cycle thinking",
      "Ctrl-O         toggle process details",
      "Ctrl-T         toggle process details",
      "Ctrl-X         copy last response",
      "/               open command completion",
      "/permissions    select permission mode",
      "Tab / Shift-Tab select command",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "Pi hotkeys" }
  )
end

return M
