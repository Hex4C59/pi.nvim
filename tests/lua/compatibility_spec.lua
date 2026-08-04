local function repository_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function assert_keys(owner, value, expected)
  assert(type(value) == "table", owner .. " is not a table")
  for _, key in ipairs(expected) do
    assert(value[key] ~= nil, ("%s lost public key %s"):format(owner, key))
  end
end

local pi = require("pi")
assert(type(pi.setup) == "function", "require('pi').setup is no longer callable")

local aliases = {
  { legacy = "pi.ui.transcript_view", owner = "pi.ui.transcript.view" },
  { legacy = "pi.ui.image_backend", owner = "pi.ui.image.backend" },
  { legacy = "pi.ui.image_backends.snacks", owner = "pi.ui.image.backends.snacks" },
  { legacy = "pi.ui.image_preview", owner = "pi.ui.image.window" },
}
for _, alias in ipairs(aliases) do
  assert(require(alias.legacy) == require(alias.owner), alias.legacy .. " no longer forwards to " .. alias.owner)
end

local config = require("pi.config")
config.setup()
local options = config.get()
assert_keys("setup options", options, {
  "command",
  "extra_args",
  "root_markers",
  "request_timeout",
  "persist_session",
  "project_trust",
  "load_context_files",
  "security",
  "output",
  "context",
  "images",
  "chat",
})
assert_keys("security options", options.security, { "mode" })
assert_keys("output options", options.output, {
  "live_max_bytes",
  "live_max_lines",
  "max_chunks",
  "tool_max_bytes",
  "transcript_max_bytes",
  "rpc_queue_max_messages",
  "rpc_queue_max_bytes",
  "render_interval_ms",
})
assert_keys("context options", options.context, {
  "max_bytes",
  "include_diagnostics",
  "diagnostics_max_count",
  "diagnostic_max_message_bytes",
  "diagnostics_max_bytes",
})
assert_keys("image options", options.images, {
  "max_bytes",
  "max_width",
  "max_height",
  "max_pixels",
  "cache_max_age_days",
  "attachment_max_count",
  "attachment_max_bytes",
  "backend",
  "preview",
  "terminal",
})
assert_keys("image preview options", options.images.preview, { "max_concurrent", "debounce_ms", "timeout_ms" })
assert_keys("terminal image options", options.images.terminal, { "provider", "auto_resize", "timeout_ms" })
assert_keys("chat options", options.chat, {
  "position",
  "width",
  "height",
  "max_input_height",
  "max_widget_height",
  "float",
})
assert_keys("floating chat options", options.chat.float, { "width", "height", "border" })

config.setup({ context = { max_chars = 4321 } })
assert(config.get().context.max_bytes == 4321, "context.max_chars no longer aliases context.max_bytes")
config.setup({ context = { max_chars = 4321, max_bytes = 1234 } })
assert(config.get().context.max_bytes == 1234, "context.max_chars overrode an explicit context.max_bytes")

dofile(vim.fs.joinpath(repository_root(), "plugin", "pi.lua"))
local commands = vim.api.nvim_get_commands({ builtin = false })
local public_commands = {
  PiChat = "0",
  PiAsk = "*",
  PiVisual = "*",
  PiBuffer = "*",
  PiAbort = "0",
  PiModel = "?",
  PiThinking = "?",
  PiPermissions = "?",
  PiSettings = "0",
  PiLayout = "?",
  PiTree = "0",
  PiFork = "0",
  PiClone = "0",
  PiCommands = "0",
  PiNew = "0",
  PiCompact = "?",
  PiStatus = "0",
  PiStop = "0",
}
for name, nargs in pairs(public_commands) do
  local command = assert(commands[name], name .. " is no longer registered")
  assert(command.nargs == nargs, ("%s nargs changed from %s to %s"):format(name, nargs, tostring(command.nargs)))
end

print("compatibility_spec: ok")
