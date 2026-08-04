local M = {}

local administrative_commands = {
  ["scoped-models"] = true,
  trust = true,
  login = true,
  logout = true,
  reload = true,
}

local removed_commands = {
  abort = true,
  changelog = true,
  clear = true,
  commands = true,
  copy = true,
  export = true,
  import = true,
  llama = true,
  mode = true,
  permission = true,
  share = true,
}

local builtins = {
  { name = "settings", description = "Open settings menu" },
  { name = "model", description = "Select model", argument_hint = "<provider/model>" },
  { name = "scoped-models", description = "Enable models for cycling", tui_only = true },
  { name = "name", description = "Set session display name", argument_hint = "<name>" },
  { name = "session", description = "Show session info and statistics" },
  { name = "hotkeys", description = "Show keyboard shortcuts" },
  { name = "fork", description = "Fork from a previous user message" },
  { name = "clone", description = "Duplicate the current session branch" },
  { name = "tree", description = "Browse the session tree" },
  { name = "trust", description = "Save project trust decision", tui_only = true },
  { name = "login", description = "Configure provider authentication", argument_hint = "<provider>", tui_only = true },
  { name = "logout", description = "Remove provider authentication", tui_only = true },
  { name = "new", description = "Start a new session" },
  { name = "compact", description = "Compact session context", argument_hint = "<instructions>" },
  { name = "resume", description = "Switch to a session file", argument_hint = "<path.jsonl>" },
  { name = "reload", description = "Reload Pi resources", tui_only = true },
  { name = "quit", description = "Close the Pi panel" },
  { name = "thinking", description = "Select thinking level", argument_hint = "<level>" },
  { name = "layout", description = "Change the Pi workspace layout", argument_hint = "<layout>" },
  {
    name = "permissions",
    description = "Select the session permission mode",
    argument_hint = "<manual|acceptEdits|auto|plan>",
  },
}

function M.is_removed(name)
  return removed_commands[name] == true
end

function M.builtin_commands(options)
  local commands = vim.deepcopy(builtins)
  if options and options.administrative_workflows then
    for _, command in ipairs(commands) do
      if administrative_commands[command.name] then
        command.tui_only = nil
      end
    end
  end
  return commands
end

function M.merge(dynamic_commands)
  local commands = M.builtin_commands({
    administrative_workflows = dynamic_commands and dynamic_commands.administrative_workflows == true,
  })
  local seen = {}
  for _, command in ipairs(commands) do
    seen[command.name] = true
  end
  for _, command in ipairs(dynamic_commands or {}) do
    if command.name and not removed_commands[command.name] and not seen[command.name] then
      table.insert(commands, vim.deepcopy(command))
      seen[command.name] = true
    end
  end
  return commands
end

return M
