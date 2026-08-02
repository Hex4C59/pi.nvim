local config = require("pi.config")
local Client = require("pi.client").Client

config.setup({
  persist_session = false,
  project_trust = "never",
  security = { mode = "confirm" },
})

local client = Client.new(vim.fn.getcwd())
local errors = {}
client:on_event(function(event)
  if event.type == "client_error" then
    table.insert(errors, event.error)
  end
end)

assert(client:start(), "client did not start")
assert(
  vim.wait(10000, function()
    return client.state == "idle" or #errors > 0
  end, 20),
  "client did not become ready"
)
assert(#errors == 0, table.concat(errors, "\n"))
assert(client.session.model ~= nil, "get_state did not return a model")

client:stop()
assert(
  vim.wait(5000, function()
    return not client:is_running()
  end, 20),
  "client did not stop"
)

print("client_smoke: ok")
