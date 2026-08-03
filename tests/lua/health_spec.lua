local config = require("pi.config")
local health = require("pi.health")

config.setup({ security = { mode = "read-only" } })
local messages = {}
local original = {
  start = vim.health.start,
  ok = vim.health.ok,
  info = vim.health.info,
  warn = vim.health.warn,
  error = vim.health.error,
}

local function run()
  for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    vim.health[level] = function(message)
      table.insert(messages, level .. ": " .. message)
    end
  end

  health.check()
end

local ok, err = xpcall(run, debug.traceback)
for level, handler in pairs(original) do
  vim.health[level] = handler
end
if not ok then
  error(err)
end

local report = table.concat(messages, "\n")
assert(report:find("Security mode: read-only", 1, true), "health report omitted the security mode")
assert(report:find("workspace-guard", 1, true), "health report omitted the workspace guard")
assert(report:find("session-root-guard", 1, true), "health report omitted the session root guard")
assert(report:find("live 64.0 KiB", 1, true), "health report omitted the live output limit")
assert(report:find("tool 256.0 KiB", 1, true), "health report omitted the per-tool limit")
assert(report:find("transcript 2.0 MiB", 1, true), "health report omitted the transcript limit")
assert(report:find("Inline image backend requested: auto", 1, true), "health report omitted requested image backend")
assert(report:find("Inline image backend active:", 1, true), "health report omitted actual image backend")
assert(report:find("40000000 pixels", 1, true), "health report omitted the decoded image limit")

print("health_spec: ok")
