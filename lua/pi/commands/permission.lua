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

function M.select(root, requested, options)
  root = root or runtime.client_root()
  local chat = runtime.chat_for(root)
  chat:open(false)
  requested = vim.trim(requested or "")
  if requested ~= "" then
    local exact = permission_mode.normalize(requested)
    if exact then
      apply(chat, exact)
      return
    end
  end

  if not mode_guard(chat) then
    return
  end
  local choices = permission_mode.options()
  if requested ~= "" then
    local query = requested:lower()
    local matches = {}
    for _, item in ipairs(choices) do
      local searchable = (item.value .. " " .. item.label):lower()
      if searchable:find(query, 1, true) then
        table.insert(matches, item)
      end
    end
    if #matches == 0 then
      notify_error(("Unknown Pi permission mode %q. Choose manual, acceptEdits, auto, or plan"):format(requested))
      return
    elseif #matches == 1 then
      apply(chat, matches[1].value)
      return
    end
    choices = matches
  end
  local current = chat:permission_mode()
  runtime.open_inline_select(root, {
    title = requested ~= "" and ("Pi permission mode - " .. requested) or "Pi permission mode",
    items = choices,
    current_key = current,
    key_item = function(item)
      return item.value
    end,
    format_item = function(item)
      return item.label
    end,
    describe_item = function(item)
      return item.description
    end,
    stack = type(options) == "table" and options.stack or nil,
    on_select = function(item)
      if item then
        apply(chat, item.value)
      end
    end,
  })
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
