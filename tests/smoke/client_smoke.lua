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
assert(type(client.session.autoRetryEnabled) == "boolean", "get_state did not return auto-retry state")
assert(
  vim.tbl_contains(client.session.rpcCapabilities or {}, "administrative_workflows"),
  "installed Pi does not advertise administrative workflows"
)

local function request(command, payload)
  local result
  local request_error
  client:request(command, payload or {}, function(success, data, err)
    if success then
      result = data or {}
    else
      request_error = err or (command .. " failed")
    end
  end)
  assert(
    vim.wait(10000, function()
      return result ~= nil or request_error ~= nil
    end, 20),
    command .. " did not complete"
  )
  assert(not request_error, request_error)
  return result
end

local providers = request("get_auth_providers").providers or {}
for _, provider in ipairs(providers) do
  assert(
    provider.apiKey == nil and provider.token == nil and provider.credential == nil,
    "provider metadata exposed a secret"
  )
end
local trust = request("get_project_trust")
assert(type(trust.active) == "boolean" and type(trust.cwd) == "string", "project trust metadata is incomplete")
local scope = request("get_model_scope")
assert(type(scope.available) == "table" and type(scope.enabled) == "table", "model scope metadata is incomplete")
local changelog = request("get_changelog", { limit = 1 })
assert(type(changelog.entries) == "table" and #changelog.entries <= 1, "bounded changelog request failed")

client:stop()
assert(
  vim.wait(5000, function()
    return not client:is_running()
  end, 20),
  "client did not stop"
)

print("client_smoke: ok")
