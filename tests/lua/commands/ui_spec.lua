local previous_modules = {
  runtime = package.loaded["pi.runtime"],
  model = package.loaded["pi.commands.model"],
  permission = package.loaded["pi.commands.permission"],
  ui = package.loaded["pi.commands.ui"],
}
local client = {
  root = "/settings-project",
  session = {
    model = { id = "fixture-model" },
    thinkingLevel = "medium",
    autoCompactionEnabled = true,
    autoRetryEnabled = true,
    steeringMode = "all",
    followUpMode = "one-at-a-time",
  },
  requests = {},
}

function client:request(command, payload, callback)
  table.insert(self.requests, { command = command, payload = payload, callback = callback })
end

local chat = {
  display_state = function()
    return {
      permission_mode_label = "Confirm",
      layout = "right",
      process_expanded = false,
    }
  end,
  toggle_process = function() end,
  current_layout = function()
    return "right"
  end,
  is_open = function()
    return true
  end,
  set_position = function(self, value)
    self.selected_layout = value
  end,
  open = function(self)
    self.opened = true
  end,
}

local errors = {}
local refresh_count = 0
local refresh_value
local menus = {}
local function open_menu(_, options)
  local surface = { closed = false, options = options }
  function surface:close()
    self.closed = true
  end
  table.insert(menus, surface)
  return surface
end
package.loaded["pi.runtime"] = {
  get_client = function()
    return client
  end,
  chat_for = function()
    return chat
  end,
  notify_error = function(err)
    table.insert(errors, err)
  end,
  refresh_state = function(refreshed_client)
    assert(refreshed_client == client, "settings refreshed the wrong client")
    refresh_count = refresh_count + 1
    refreshed_client.session.autoRetryEnabled = refresh_value
  end,
  open_inline_select = open_menu,
}
local model_calls = {}
package.loaded["pi.commands.model"] = {
  select_model = function(...)
    table.insert(model_calls, { kind = "model", args = { ... } })
  end,
  select_thinking_level = function(...)
    table.insert(model_calls, { kind = "thinking", args = { ... } })
  end,
}
local permission_calls = {}
package.loaded["pi.commands.permission"] = {
  select = function(...)
    table.insert(permission_calls, { ... })
  end,
}
package.loaded["pi.commands.ui"] = nil

local function find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
end

local function open_settings(commands)
  commands.settings(client.root)
  return menus[#menus]
end

local function run()
  local commands = require("pi.commands.ui")

  local model_menu = open_settings(commands)
  model_menu.options.on_select(assert(find_item(model_menu.options.items, "Model")))
  assert(
    model_calls[1].kind == "model" and model_calls[1].args[3].stack == "push",
    "settings model action did not request an inline submenu"
  )

  local permission_menu = open_settings(commands)
  permission_menu.options.on_select(assert(find_item(permission_menu.options.items, "Permission mode")))
  assert(permission_calls[1][3].stack == "push", "settings permission action did not request an inline submenu")

  commands.layout(nil, client.root)
  local layout_menu = menus[#menus]
  assert(layout_menu.options.title == "Pi layout" and layout_menu.options.current == "right", "layout menu lost state")
  layout_menu.options.on_select("bottom")
  assert(chat.selected_layout == "bottom", "layout selection did not reach the Chat shell")

  chat.selected_layout = nil
  commands.layout("t", client.root)
  local filtered_layout_menu = menus[#menus]
  assert(filtered_layout_menu.options.title == "Pi layout - t", "ambiguous layout query did not open a menu")
  assert(#filtered_layout_menu.options.items > 1, "ambiguous layout query lost matching candidates")
  assert(chat.selected_layout == nil, "ambiguous layout query changed the layout before selection")

  commands.layout("bot", client.root)
  assert(chat.selected_layout == "bottom", "unique partial layout query was not applied directly")

  local menu = open_settings(commands)
  local retry = assert(find_item(menu.options.items, "Auto-retry"), "settings omitted auto-retry")
  assert(retry.value == "on", "settings did not display enabled auto-retry")
  menu.options.on_select(retry)
  assert(menu.closed, "final settings action did not close the inline menu group")
  local failed = client.requests[#client.requests]
  assert(
    failed.command == "set_auto_retry" and failed.payload.enabled == false,
    "enabled auto-retry did not request disable"
  )
  assert(client.session.autoRetryEnabled == true, "settings changed retry state before the RPC response")
  failed.callback(false, nil, "retry setting failed")
  assert(client.session.autoRetryEnabled == true, "failed retry toggle changed the state mirror")
  assert(refresh_count == 0 and errors[#errors] == "retry setting failed", "failed retry toggle was not reported")

  menu = open_settings(commands)
  menu.options.on_select(assert(find_item(menu.options.items, "Auto-retry")))
  local succeeded = client.requests[#client.requests]
  assert(client.session.autoRetryEnabled == true, "retry state changed before authoritative refresh")
  refresh_value = false
  succeeded.callback(true, {})
  assert(refresh_count == 1 and client.session.autoRetryEnabled == false, "successful toggle did not refresh state")

  client.session.autoRetryEnabled = nil
  menu = open_settings(commands)
  retry = assert(find_item(menu.options.items, "Auto-retry"))
  assert(retry.value == "unknown", "missing retry capability did not display unknown")
  menu.options.on_select(retry)
  local retry_menu = menus[#menus]
  assert(retry_menu.options.title == "Set Pi auto-retry", "unknown retry state did not require an explicit choice")
  assert(retry_menu.options.stack == "push", "unknown retry state did not open as a settings submenu")
  assert(#client.requests == 2, "unknown retry state guessed a toggle value")
  local disable = assert(find_item(retry_menu.options.items, "Disable"), "explicit disable choice is missing")
  retry_menu.options.on_select(disable)
  local explicit = client.requests[#client.requests]
  assert(explicit.payload.enabled == false, "explicit unknown-state choice sent the wrong value")
  refresh_value = false
  explicit.callback(true, {})
  assert(refresh_count == 2 and client.session.autoRetryEnabled == false, "explicit retry setting was not refreshed")

  client.session.autoCompactionEnabled = true
  menu = open_settings(commands)
  menu.options.on_select(assert(find_item(menu.options.items, "Auto-compact")))
  local compaction = client.requests[#client.requests]
  assert(
    compaction.command == "set_auto_compaction" and compaction.payload.enabled == false,
    "auto-compact request changed"
  )
  assert(client.session.autoCompactionEnabled == true, "auto-compact changed before authoritative refresh")
  compaction.callback(true, {})
  assert(
    refresh_count == 3 and client.session.autoCompactionEnabled == true,
    "auto-compact did not request a state refresh"
  )

  menu = open_settings(commands)
  menu.options.on_select(assert(find_item(menu.options.items, "Steering mode")))
  local steering = client.requests[#client.requests]
  assert(
    steering.command == "set_steering_mode" and steering.payload.mode == "one-at-a-time",
    "steering request changed"
  )
  steering.callback(true, {})
  assert(refresh_count == 4 and client.session.steeringMode == "all", "steering mode bypassed authoritative refresh")

  menu = open_settings(commands)
  menu.options.on_select(assert(find_item(menu.options.items, "Follow-up mode")))
  local followup = client.requests[#client.requests]
  followup.callback(false, nil, "follow-up setting failed")
  assert(refresh_count == 4 and client.session.followUpMode == "one-at-a-time", "failed follow-up changed local state")
  assert(errors[#errors] == "follow-up setting failed", "failed follow-up was not reported")
end

local ok, err = xpcall(run, debug.traceback)
package.loaded["pi.runtime"] = previous_modules.runtime
package.loaded["pi.commands.model"] = previous_modules.model
package.loaded["pi.commands.permission"] = previous_modules.permission
package.loaded["pi.commands.ui"] = previous_modules.ui
if not ok then
  error(err)
end

print("ui_spec: ok")
