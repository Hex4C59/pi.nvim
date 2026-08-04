local pi = require("pi")
local catalog = require("pi.commands.catalog")
local runtime = require("pi.runtime")

local root = vim.fn.getcwd()
local calls = { prompts = {} }
local removed_commands = {
  "mode",
  "permission",
  "clear",
  "commands",
  "changelog",
  "export",
  "import",
  "share",
  "abort",
  "llama",
  "copy",
}
local removed_apis = {
  "commands",
  "copy_last_response",
  "export_session",
  "import_session",
  "share",
  "changelog",
}
local patched_functions = {
  "select_model",
  "select_thinking_level",
  "settings",
  "layout",
  "compact",
  "tree",
  "bash",
  "new_session",
  "select_permission_mode",
  "abort",
  "login",
  "logout",
  "trust",
  "reload",
  "scoped_models",
}
local originals = {}
for _, name in ipairs(patched_functions) do
  originals[name] = pi[name]
end
local original_send_prompt = runtime.send_prompt
local original_notify = vim.notify

local function run()
  local expected_builtin_commands = {
    "settings",
    "model",
    "scoped-models",
    "name",
    "session",
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
    "thinking",
    "layout",
    "permissions",
  }
  local builtin_commands = catalog.builtin_commands()
  assert(#builtin_commands == #expected_builtin_commands, "Pi builtin command catalog contains an unexpected command")
  for index, name in ipairs(expected_builtin_commands) do
    assert(builtin_commands[index].name == name, "Pi builtin command catalog is incomplete or out of order")
  end
  local first_name = builtin_commands[1].name
  builtin_commands[1].name = "mutated"
  assert(catalog.builtin_commands()[1].name == first_name, "builtin command reads share mutable state")

  local dynamic = { { name = first_name }, { name = "dynamic", description = "Dynamic" } }
  for _, name in ipairs(removed_commands) do
    table.insert(dynamic, { name = name, description = "Removed dynamic command" })
  end
  local merged = catalog.merge(dynamic)
  assert(
    merged[#merged].name == "dynamic" and #merged == #catalog.builtin_commands() + 1,
    "command merge changed precedence"
  )
  local visible = {}
  for _, command in ipairs(merged) do
    visible[command.name] = true
  end
  for _, name in ipairs(removed_commands) do
    assert(not visible[name], "removed command reappeared from the dynamic catalogue: /" .. name)
  end

  local capable = catalog.merge({ administrative_workflows = true })
  for _, command in ipairs(capable) do
    if command.name == "login" or command.name == "scoped-models" then
      assert(not command.tui_only, "administrative capability did not enable native command metadata")
    end
  end

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
  pi.new_session = function(value)
    calls.new_session = value
  end
  pi.select_permission_mode = function(value, mode)
    calls.permissions = { value, mode }
  end
  pi.abort = function(value)
    calls.abort = value
  end
  pi.login = function(value, query)
    calls.login = { value, query }
  end
  pi.logout = function(value, query)
    calls.logout = { value, query }
  end
  pi.trust = function(value)
    calls.trust = value
  end
  pi.reload = function(value)
    calls.reload = value
  end
  pi.scoped_models = function(value)
    calls.scoped_models = value
  end

  local notifications = {}
  vim.notify = function(message, level, options)
    table.insert(notifications, { message = message, level = level, options = options })
  end
  runtime.send_prompt = function(text, _, value)
    table.insert(calls.prompts, { text = text, root = value })
  end

  pi.submit("/model openai/gpt-test", root)
  pi.submit("/thinking high", root)
  pi.submit("/settings", root)
  pi.submit("/layout float", root)
  pi.submit("/compact focus on tools", root)
  pi.submit("/tree", root)
  pi.submit("/new", root)
  pi.submit("/permissions auto", root)
  pi.submit("/login fixture", root)
  pi.submit("/logout fixture", root)
  pi.submit("/trust", root)
  pi.submit("/reload", root)
  pi.submit("/scoped-models", root)
  pi.submit("!printf hello", root)
  for _, name in ipairs(removed_commands) do
    pi.submit("/" .. name .. " ignored", root)
  end
  pi.submit("/fixture-extension value", root)
  pi.abort(root)

  assert(calls.model == root and calls.model_query == "openai/gpt-test", "model command was not routed")
  assert(calls.thinking == root and calls.thinking_level == "high", "thinking command was not routed")
  assert(calls.settings == root, "settings command was not routed")
  assert(calls.layout[1] == "float" and calls.layout[2] == root, "layout command was not routed")
  assert(calls.compact[1] == "focus on tools" and calls.compact[2] == root, "compact arguments were lost")
  assert(calls.tree == root, "tree command was not routed")
  assert(calls.new_session == root, "new command did not start a fresh session")
  assert(calls.permissions[1] == root and calls.permissions[2] == "auto", "permission mode command was not routed")
  assert(calls.abort == root, "the retained abort API did not route to its implementation")
  assert(calls.login[1] == root and calls.login[2] == "fixture", "login command was not routed")
  assert(calls.logout[1] == root and calls.logout[2] == "fixture", "logout command was not routed")
  assert(calls.trust == root and calls.reload == root, "trust or reload command was not routed")
  assert(calls.scoped_models == root, "scoped-models command was not routed")
  assert(calls.bash[1] == "printf hello" and calls.bash[2] == root, "bash command was not routed")
  assert(#notifications == #removed_commands, "a removed slash command did not produce exactly one warning")
  for index, notification in ipairs(notifications) do
    assert(
      notification.level == vim.log.levels.WARN
        and notification.message:find("not supported by pi.nvim", 1, true)
        and notification.message:find("/" .. removed_commands[index], 1, true),
      "removed slash command warning is imprecise"
    )
  end
  assert(
    #calls.prompts == 1 and calls.prompts[1].text == "/fixture-extension value",
    "removed command reached the model prompt path"
  )
  for _, name in ipairs(removed_apis) do
    assert(pi[name] == nil, "removed public Lua API remains exported: " .. name)
  end
end

local ok, err = xpcall(run, debug.traceback)
vim.notify = original_notify
runtime.send_prompt = original_send_prompt
for _, name in ipairs(patched_functions) do
  pi[name] = originals[name]
end
if not ok then
  error(err)
end

print("dispatch_spec: ok")
