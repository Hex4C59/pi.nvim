local config = require("pi.config")

local root = vim.fn.getcwd()
local plugin_root = vim.fs.normalize(root)

config.setup({
  persist_session = false,
  project_trust = "never",
  load_context_files = false,
  security = { mode = "confirm" },
  provider = "example-provider",
  model = "example-model",
  thinking = "high",
  extra_args = { "--name", "pi.nvim test" },
})

local command = config.command(root)
local joined = table.concat(command, "\n")
assert(config.get().chat.position == "right", "right split must be the default chat layout")
assert(config.get().chat.max_widget_height == 8, "widget height limit must have a stable default")
assert(command[1] == "pi", "Pi executable must be first")
assert(joined:find("--mode\nrpc", 1, true), "RPC mode is required")
assert(joined:find("--no-approve", 1, true), "project trust flag is missing")
assert(joined:find("--no-context-files", 1, true), "context file flag is missing")
assert(joined:find("--no-session", 1, true), "ephemeral session flag is missing")
assert(joined:find("--provider\nexample-provider", 1, true), "provider flag is missing")
assert(joined:find("--model\nexample-model", 1, true), "model flag is missing")
assert(joined:find("--thinking\nhigh", 1, true), "thinking flag is missing")
assert(
  joined:find(vim.fs.joinpath(plugin_root, "extensions", "permission-gate.ts"), 1, true),
  "extension path is wrong"
)
assert(
  joined:find(vim.fs.joinpath(plugin_root, "extensions", "session-root-guard.ts"), 1, true),
  "session root guard must be loaded in confirm mode"
)
assert(joined:find(vim.fs.joinpath(plugin_root, "extensions", "todo.ts"), 1, true), "todo extension must be loaded")

config.setup({ context = { max_chars = 321 } })
assert(config.get().context.max_bytes == 321, "legacy context.max_chars was not migrated")
config.setup({ context = { max_chars = 321, max_bytes = 654 } })
assert(config.get().context.max_bytes == 654, "context.max_bytes must take precedence over the legacy alias")

config.setup({ security = { mode = "read-only" } })
local read_only = table.concat(config.command(root), "\n")
assert(read_only:find("--tools\nread,grep,find,ls,todo", 1, true), "read-only tools are missing")
assert(
  read_only:find(vim.fs.joinpath(plugin_root, "extensions", "workspace-guard.ts"), 1, true),
  "read-only workspace guard is missing"
)
assert(
  read_only:find(vim.fs.joinpath(plugin_root, "extensions", "session-root-guard.ts"), 1, true),
  "session root guard must be loaded in read-only mode"
)

config.setup({ security = { mode = "full" } })
local full = table.concat(config.command(root), "\n")
assert(not full:find("permission%-gate"), "full mode must not load permission gate")
assert(not full:find("workspace%-guard"), "full mode must not load workspace guard")
assert(full:find("session%-root%-guard"), "full mode must still load session root guard")

for _, invalid in ipairs({ 0, -1, "50", math.huge }) do
  local ok = pcall(config.setup, { output = { live_max_bytes = invalid } })
  assert(not ok, "invalid output limit was accepted: " .. vim.inspect(invalid))
end
assert(not pcall(config.setup, { output = { render_interval_ms = 49 } }), "render interval below 50 ms was accepted")
assert(
  not pcall(config.setup, { output = { rpc_queue_max_messages = 0 } }),
  "zero RPC queue message limit was accepted"
)
assert(not pcall(config.setup, { output = { rpc_queue_max_bytes = -1 } }), "negative RPC queue byte limit was accepted")

config.setup({ output = { render_interval_ms = 50.9 } })
assert(config.get().output.render_interval_ms == 50, "output limits must be normalized to integers")

for _, backend in ipairs({ "blocks", "kitty", "" }) do
  assert(not pcall(config.setup, { images = { backend = backend } }), "invalid image backend was accepted: " .. backend)
end
assert(
  not pcall(config.setup, { images = { terminal = { provider = "unknown" } } }),
  "unknown terminal image provider was accepted"
)
assert(
  not pcall(config.setup, { images = { terminal = { auto_resize = "yes" } } }),
  "non-boolean image auto-resize was accepted"
)
assert(
  not pcall(config.setup, { images = { terminal = { timeout_ms = 99 } } }),
  "unsafe image conversion timeout was accepted"
)
config.setup({ images = { terminal = { timeout_ms = 1000.9 } } })
assert(config.get().images.terminal.timeout_ms == 1000, "image timeout must be normalized to an integer")

print("config_spec: ok")
