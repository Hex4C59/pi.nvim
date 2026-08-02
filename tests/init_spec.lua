local root = vim.fn.getcwd()
local listeners = {}
local fake_client = {
  root = root,
  state = "idle",
  session = {},
}

function fake_client:on_event(listener)
  table.insert(listeners, listener)
end

function fake_client:start()
  return true
end

function fake_client:stop() end

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

print("init_spec: ok")
