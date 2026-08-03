local M = {}

local builtins = {
  { name = "settings", description = "Open settings menu" },
  { name = "model", description = "Select model", argument_hint = "<provider/model>" },
  { name = "scoped-models", description = "Enable models for cycling", tui_only = true },
  { name = "export", description = "Export session to HTML", argument_hint = "<path.html>" },
  { name = "import", description = "Import a session from JSONL", argument_hint = "<path.jsonl>", tui_only = true },
  { name = "share", description = "Share session as a secret GitHub gist", tui_only = true },
  { name = "copy", description = "Copy last agent message" },
  { name = "name", description = "Set session display name", argument_hint = "<name>" },
  { name = "session", description = "Show session info and statistics" },
  { name = "changelog", description = "Show Pi changelog", tui_only = true },
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
  { name = "commands", description = "Browse available commands" },
  { name = "abort", description = "Abort the active operation" },
  { name = "clear", description = "Clear the conversation and start a fresh session" },
  {
    name = "permissions",
    description = "Select the session permission mode",
    argument_hint = "<manual|acceptEdits|auto|plan>",
  },
  { name = "mode", description = "Alias for /permissions", argument_hint = "<manual|acceptEdits|auto|plan>" },
}

function M.builtin_commands()
  return vim.deepcopy(builtins)
end

function M.merge(dynamic_commands)
  local commands = M.builtin_commands()
  local seen = {}
  for _, command in ipairs(commands) do
    seen[command.name] = true
  end
  for _, command in ipairs(dynamic_commands or {}) do
    if command.name and not seen[command.name] then
      table.insert(commands, vim.deepcopy(command))
      seen[command.name] = true
    end
  end
  return commands
end

return M
