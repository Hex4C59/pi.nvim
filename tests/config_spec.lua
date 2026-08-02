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

config.setup({ context = { max_chars = 321 } })
assert(config.get().context.max_bytes == 321, "legacy context.max_chars was not migrated")
config.setup({ context = { max_chars = 321, max_bytes = 654 } })
assert(config.get().context.max_bytes == 654, "context.max_bytes must take precedence over the legacy alias")

config.setup({ security = { mode = "read-only" } })
local read_only = table.concat(config.command(root), "\n")
assert(read_only:find("--tools\nread,grep,find,ls", 1, true), "read-only tools are missing")

print("config_spec: ok")
