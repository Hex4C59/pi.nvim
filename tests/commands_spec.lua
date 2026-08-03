local pi = require("pi")
local builtin_commands = require("pi.ui.chat").builtin_commands
local root = vim.fn.getcwd()
local calls = {}

local expected_builtin_commands = {
  "settings",
  "model",
  "scoped-models",
  "export",
  "import",
  "share",
  "copy",
  "name",
  "session",
  "changelog",
  "hotkeys",
  "fork",
  "clone",
  "tree",
  "trust",
  "login",
  "logout",
  "new",
  "compact",
  "resume",
  "reload",
  "quit",
}
for index, name in ipairs(expected_builtin_commands) do
  assert(builtin_commands[index].name == name, "Pi builtin command catalog is incomplete or out of order")
end
assert(#builtin_commands >= #expected_builtin_commands, "Pi builtin command catalog is incomplete")

pi.select_model = function(value, query)
  calls.model = value
  calls.model_query = query
end
pi.select_thinking_level = function(value, level)
  calls.thinking = value
  calls.thinking_level = level
end
pi.settings = function(value)
  calls.settings = value
end
pi.layout = function(layout, value)
  calls.layout = { layout, value }
end
pi.compact = function(instructions, value)
  calls.compact = { instructions, value }
end
pi.tree = function(value)
  calls.tree = value
end
pi.bash = function(command, value)
  calls.bash = { command, value }
end
pi.copy_last_response = function(value)
  calls.copy = value
end
pi.new_session = function(value)
  calls.new_session = value
end

pi.submit("/model openai/gpt-test", root)
pi.submit("/thinking high", root)
pi.submit("/settings", root)
pi.submit("/layout float", root)
pi.submit("/compact focus on tools", root)
pi.submit("/tree", root)
pi.submit("/copy", root)
pi.submit("/clear", root)
pi.submit("!printf hello", root)

assert(calls.model == root, "model command was not routed")
assert(calls.model_query == "openai/gpt-test", "model command arguments were lost")
assert(calls.thinking == root, "thinking command was not routed")
assert(calls.thinking_level == "high", "thinking command arguments were lost")
assert(calls.settings == root, "settings command was not routed")
assert(calls.layout[1] == "float" and calls.layout[2] == root, "layout command was not routed")
assert(calls.compact[1] == "focus on tools" and calls.compact[2] == root, "compact arguments were lost")
assert(calls.tree == root, "tree command was not routed")
assert(calls.copy == root, "copy command was not routed")
assert(calls.new_session == root, "clear command did not start a fresh session")
assert(calls.bash[1] == "printf hello" and calls.bash[2] == root, "bash command was not routed")

local warning = nil
local original_notify = vim.notify
vim.notify = function(message, level)
  warning = { message = message, level = level }
end
pi.submit("/login openai", root)
vim.notify = original_notify
assert(warning and warning.level == vim.log.levels.WARN, "TUI-only command did not show an RPC warning")
assert(warning.message:find("not exposed", 1, true), "RPC warning did not explain the unavailable command")

print("commands_spec: ok")
