local pi = require("pi")

local root = vim.fn.getcwd()
local warning = nil
local original_notify = vim.notify
local function run()
  vim.notify = function(message, level)
    warning = { message = message, level = level }
  end
  pi.submit("/login openai", root)
  vim.notify = original_notify
  assert(warning and warning.level == vim.log.levels.WARN, "TUI-only command did not show an RPC warning")
  assert(warning.message:find("not exposed", 1, true), "RPC warning did not explain the unavailable command")
end

local ok, err = xpcall(run, debug.traceback)
vim.notify = original_notify
if not ok then
  error(err)
end

print("rpc_limitations_spec: ok")
