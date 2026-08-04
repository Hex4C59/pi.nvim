local config = require("pi.config")
local context = require("pi.context")
local runtime = require("pi.runtime")

local model_cmds = require("pi.commands.model")
local session_cmds = require("pi.commands.session")
local action_cmds = require("pi.commands.action")
local ui_cmds = require("pi.commands.ui")
local permission_cmds = require("pi.commands.permission")
local admin_cmds = require("pi.commands.admin")

local M = {}

-- Frozen command exports. M.submit dispatches through M.* so callers can
-- replace individual commands at runtime (see tests/lua/commands/dispatch_spec.lua).
M.select_model = model_cmds.select_model
M.select_thinking_level = model_cmds.select_thinking_level
M.cycle_model = model_cmds.cycle_model
M.cycle_thinking_level = model_cmds.cycle_thinking_level
M.new_session = session_cmds.new_session
M.compact = session_cmds.compact
M.status = session_cmds.status
M.tree = session_cmds.tree
M.fork = session_cmds.fork
M.clone = session_cmds.clone
M.name_session = session_cmds.name_session
M.export_session = session_cmds.export_session
M.resume = session_cmds.resume
M.commands = session_cmds.commands
M.ask = action_cmds.ask
M.visual = action_cmds.visual
M.buffer = action_cmds.buffer
M.abort = action_cmds.abort
M.bash = action_cmds.bash
M.copy_last_response = action_cmds.copy_last_response
M.layout = ui_cmds.layout
M.settings = ui_cmds.settings
M.hotkeys = ui_cmds.hotkeys
M.select_permission_mode = permission_cmds.select
M.cycle_permission_mode = permission_cmds.cycle
M.login = admin_cmds.login
M.logout = admin_cmds.logout
M.trust = admin_cmds.trust
M.reload = admin_cmds.reload
M.scoped_models = admin_cmds.scoped_models
M.import_session = admin_cmds.import_session
M.share = admin_cmds.share
M.changelog = admin_cmds.changelog

function M.setup(opts)
  config.setup(opts)
end

function M.chat()
  local path = vim.api.nvim_buf_get_name(0)
  local client = runtime.get_client()
  local chat = runtime.chat_for(client.root)
  chat:set_path(path)
  chat:open()
end

function M.submit(text, root, behavior, images)
  text = vim.trim(text or "")
  if text == "" and (#(images or {}) == 0) then
    return
  end
  root = root or runtime.client_root()
  local command, arguments = text:match("^/([%w:_-]+)%s*(.*)$")
  if command == "model" then
    M.select_model(root, arguments)
  elseif command == "thinking" then
    M.select_thinking_level(root, arguments)
  elseif command == "permissions" or command == "permission" then
    M.select_permission_mode(root, arguments)
  elseif command == "mode" then
    M.select_permission_mode(root, arguments)
  elseif command == "settings" then
    M.settings(root)
  elseif command == "layout" then
    M.layout(arguments, root)
  elseif command == "new" then
    M.new_session(root)
  elseif command == "compact" then
    M.compact(arguments, root)
  elseif command == "session" then
    M.status(root)
  elseif command == "tree" then
    M.tree(root)
  elseif command == "fork" then
    M.fork(root)
  elseif command == "clone" then
    M.clone(root)
  elseif command == "name" then
    M.name_session(arguments, root)
  elseif command == "export" then
    M.export_session(arguments, root)
  elseif command == "resume" then
    M.resume(arguments, root)
  elseif command == "copy" then
    M.copy_last_response(root)
  elseif command == "commands" then
    M.commands(root)
  elseif command == "hotkeys" then
    M.hotkeys()
  elseif command == "login" then
    M.login(root, arguments)
  elseif command == "logout" then
    M.logout(root, arguments)
  elseif command == "trust" then
    M.trust(root)
  elseif command == "reload" then
    M.reload(root)
  elseif command == "scoped-models" then
    M.scoped_models(root)
  elseif command == "import" then
    M.import_session(root, arguments)
  elseif command == "share" then
    M.share(root)
  elseif command == "changelog" then
    M.changelog(root)
  elseif command == "abort" then
    M.abort(root)
  elseif command == "clear" then
    M.new_session(root)
  elseif command == "quit" then
    runtime.chat_for(root):close()
  elseif command and runtime.rpc_unavailable_commands[command] then
    vim.notify(runtime.rpc_unavailable_commands[command], vim.log.levels.WARN, { title = "Pi /" .. command })
  elseif text:sub(1, 1) == "!" then
    M.bash(text:sub(text:sub(1, 2) == "!!" and 3 or 2), root)
  else
    runtime.send_prompt(text, nil, root, behavior, images)
  end
end

runtime.set_ui_actions({
  submit = M.submit,
  abort = M.abort,
  select_model = M.select_model,
  cycle_model = M.cycle_model,
  cycle_permission_mode = M.cycle_permission_mode,
  cycle_thinking_level = M.cycle_thinking_level,
  admin_event = admin_cmds.handle_event,
  admin_discard = admin_cmds.discard,
})

function M.track_buffer(bufnr)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  path = vim.fs.normalize(path)
  for root, chat in pairs(runtime.chats) do
    if context.is_within_root(root, path) then
      chat:set_path(path)
    end
  end
end

function M.stop()
  local root = runtime.client_root()
  runtime.stop(root)
end

function M.stop_all()
  runtime.stop_all()
end

return M
