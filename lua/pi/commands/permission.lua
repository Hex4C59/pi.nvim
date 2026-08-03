local config = require("pi.config")
local permission_mode = require("pi.permission_mode")
local runtime = require("pi.runtime")

local M = {}

local function notify_error(message)
  runtime.notify_error(message)
end

local function mode_guard(chat)
  local security_mode = (config.get().security or {}).mode
  if security_mode ~= "confirm" then
    notify_error(
      ("Runtime permission modes are locked by security.mode = %q; use security.mode = \"confirm\" to switch modes"):format(
        security_mode
      )
    )
    return false
  end
  if chat:has_active_permission_request() then
    notify_error("Finish the active permission prompt before changing permission mode")
    return false
  end
  return true
end

local function apply(chat, value)
  local mode = permission_mode.normalize(value)
  if not mode then
    notify_error(("Unknown Pi permission mode %q. Choose manual, acceptEdits, auto, or plan"):format(tostring(value)))
    return false
  end
  if not mode_guard(chat) then
    return false
  end
  runtime.send_prompt("/permissions " .. mode, nil, chat:project_root())
  return true
end

function M.select(root, requested)
  root = root or runtime.client_root()
  local chat = runtime.chat_for(root)
  chat:open(false)
  requested = vim.trim(requested or "")
  if requested ~= "" then
    apply(chat, requested)
    return
  end

  if not mode_guard(chat) then
    return
  end
  local current = chat:permission_mode()
  vim.ui.select(permission_mode.options(), {
    prompt = "Pi permission mode",
    format_item = function(item)
      local marker = item.value == current and "●" or " "
      return ("%s %-13s %s"):format(marker, item.label, item.description)
    end,
  }, function(item)
    if item then
      apply(chat, item.value)
    end
  end)
end

function M.cycle(root, delta)
  root = root or runtime.client_root()
  local chat = runtime.chat_for(root)
  chat:open(false)
  if not mode_guard(chat) then
    return
  end
  local current = chat:permission_mode()
  if not current then
    M.select(root)
    return
  end
  apply(chat, permission_mode.cycle(current, delta or 1))
end

M.set = M.select
M.show = M.select

return M
