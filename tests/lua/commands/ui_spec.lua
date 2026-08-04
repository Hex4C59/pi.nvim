local previous_modules = {
  runtime = package.loaded["pi.runtime"],
  model = package.loaded["pi.commands.model"],
  permission = package.loaded["pi.commands.permission"],
  ui = package.loaded["pi.commands.ui"],
}
local previous_select = vim.ui.select

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
}

local errors = {}
local refresh_count = 0
local refresh_value
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
}
package.loaded["pi.commands.model"] = {
  select_model = function() end,
  select_thinking_level = function() end,
}
package.loaded["pi.commands.permission"] = { select = function() end }
package.loaded["pi.commands.ui"] = nil

local function find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
end

local function open_settings(commands)
  local selection = {}
  vim.ui.select = function(items, options, callback)
    selection.items = items
    selection.options = options
    selection.callback = callback
  end
  commands.settings(client.root)
  return selection
end

local function run()
  local commands = require("pi.commands.ui")

  local menu = open_settings(commands)
  local retry = assert(find_item(menu.items, "Auto-retry"), "settings omitted auto-retry")
  assert(retry.value == "on", "settings did not display enabled auto-retry")
  menu.callback(retry)
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
  menu.callback(assert(find_item(menu.items, "Auto-retry")))
  local succeeded = client.requests[#client.requests]
  assert(client.session.autoRetryEnabled == true, "retry state changed before authoritative refresh")
  refresh_value = false
  succeeded.callback(true, {})
  assert(refresh_count == 1 and client.session.autoRetryEnabled == false, "successful toggle did not refresh state")

  client.session.autoRetryEnabled = nil
  menu = open_settings(commands)
  retry = assert(find_item(menu.items, "Auto-retry"))
  assert(retry.value == "unknown", "missing retry capability did not display unknown")
  menu.callback(retry)
  assert(menu.options.prompt == "Set Pi auto-retry", "unknown retry state did not require an explicit choice")
  assert(#client.requests == 2, "unknown retry state guessed a toggle value")
  local disable = assert(find_item(menu.items, "Disable"), "explicit disable choice is missing")
  menu.callback(disable)
  local explicit = client.requests[#client.requests]
  assert(explicit.payload.enabled == false, "explicit unknown-state choice sent the wrong value")
  refresh_value = false
  explicit.callback(true, {})
  assert(refresh_count == 2 and client.session.autoRetryEnabled == false, "explicit retry setting was not refreshed")
end

local ok, err = xpcall(run, debug.traceback)
vim.ui.select = previous_select
package.loaded["pi.runtime"] = previous_modules.runtime
package.loaded["pi.commands.model"] = previous_modules.model
package.loaded["pi.commands.permission"] = previous_modules.permission
package.loaded["pi.commands.ui"] = previous_modules.ui
if not ok then
  error(err)
end

print("ui_spec: ok")
