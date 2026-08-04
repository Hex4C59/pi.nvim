local pi = require("pi")
local runtime = require("pi.runtime")

local root = vim.fn.getcwd()
local warning = nil
local original_notify = vim.notify
local original_get_client = runtime.get_client
local original_client_is_current = runtime.client_is_current
local function run()
  vim.notify = function(message, level)
    warning = { message = message, level = level }
  end
  runtime.get_client = function()
    return { root = root, session = { rpcCapabilities = {} } }
  end
  runtime.client_is_current = function()
    return true
  end
  pi.submit("/login openai", root)
  vim.notify = original_notify
  assert(warning and warning.level == vim.log.levels.WARN, "TUI-only command did not show an RPC warning")
  assert(warning.message:find("does not advertise", 1, true), "RPC warning did not explain the capability gap")
end

local ok, err = xpcall(run, debug.traceback)
vim.notify = original_notify
runtime.get_client = original_get_client
runtime.client_is_current = original_client_is_current
if not ok then
  error(err)
end

print("rpc_limitations_spec: ok")
