local root = vim.fn.getcwd()
local listeners = {}
local registered_listener
local unsubscribe_calls = 0
local stop_calls = 0
local late_events_emitted = false
local fake_client = {
  root = root,
  state = "idle",
  session = {},
}

function fake_client:on_event(listener)
  table.insert(listeners, listener)
  registered_listener = listener
  return function()
    unsubscribe_calls = unsubscribe_calls + 1
    for index, candidate in ipairs(listeners) do
      if candidate == listener then
        table.remove(listeners, index)
        break
      end
    end
  end
end

function fake_client:start()
  return true
end

function fake_client:stop()
  stop_calls = stop_calls + 1
  local queued_listener = registered_listener
  vim.schedule(function()
    queued_listener({
      type = "message_start",
      message = { role = "user", content = { { type = "text", text = "late" } } },
    })
    queued_listener({ type = "client_exit", code = 0, expected = true, stderr = "" })
    late_events_emitted = true
  end)
end

function fake_client:request(command, _, callback)
  if command == "bash" then
    callback(false, nil, "fixture write failure")
    return nil
  end
  return "fixture-request"
end

package.loaded["pi"] = nil
package.loaded["pi.client"] = {
  Client = {
    new = function()
      return fake_client
    end,
  },
}

local notification
local original_notify = vim.notify
vim.notify = function(message, level)
  notification = { message = message, level = level }
end

require("pi").bash("printf fixture", root)
vim.notify = original_notify

assert(notification, "a synchronous Bash send failure was silently dropped")
assert(notification.message:find("fixture write failure", 1, true), "the Bash send failure lost its cause")
assert(notification.level == vim.log.levels.ERROR, "the Bash send failure did not use error severity")

local runtime = require("pi.runtime")
assert(runtime.chats[root], "Bash fixture did not create a Chat")
require("pi").stop()
assert(runtime.clients[root] == nil and runtime.chats[root] == nil, "PiStop retained the project Client or Chat")
require("pi").stop()
assert(stop_calls == 1, "repeated PiStop stopped an already detached client again")
assert(unsubscribe_calls == 1, "PiStop did not unsubscribe the runtime listener exactly once")
assert(
  vim.wait(500, function()
    return late_events_emitted
  end, 10),
  "late client events were not emitted by the fixture"
)
assert(
  runtime.clients[root] == nil and runtime.chats[root] == nil,
  "late client events recreated runtime state after PiStop"
)

print("init_spec: ok")
