local surface = require("pi.ui.dialog_surface")

local M = {}
local managers = setmetatable({}, { __mode = "k" })

local function permission_select(request)
  local options = request.options
  return type(options) == "table"
    and #options == 3
    and options[1] == "Block"
    and options[2] == "Allow once"
    and options[3] == "Allow for session"
end

local function permission_request(request)
  local copy = vim.deepcopy(request)
  local title, message = (copy.title or "Permission required"):match("^([^\n]*)\n?(.*)$")
  copy.title = title
  copy.message = message
  return copy
end

local function manager_for(client)
  local manager = managers[client]
  if manager then
    return manager
  end
  manager = {
    client = client,
    by_id = {},
    queue = {},
    active = nil,
    discarding = false,
  }
  managers[client] = manager
  return manager
end

local function remove_queued(manager, entry)
  for index, candidate in ipairs(manager.queue) do
    if candidate == entry then
      table.remove(manager.queue, index)
      return
    end
  end
end

local advance

local function finish(manager, entry, response, send_response)
  if entry.finished then
    return false
  end
  entry.finished = true
  manager.by_id[entry.request.id] = nil
  remove_queued(manager, entry)
  if manager.active == entry then
    manager.active = nil
  end
  if entry.surface then
    entry.surface:close()
    entry.surface = nil
  elseif entry.cancel_external then
    entry.cancel_external()
  end
  if send_response then
    manager.client:respond_ui(entry.request.id, response)
  end
  if not manager.discarding then
    advance(manager)
  end
  return true
end

local function activate_permission(manager, entry)
  local handlers = entry.handlers
  entry.cancel_external = function()
    if handlers.cancel_permission then
      handlers.cancel_permission(entry.request.id)
    end
  end
  handlers.permission_select(permission_request(entry.request), function(choice)
    if type(choice) == "string" then
      finish(manager, entry, { value = choice }, true)
    else
      finish(manager, entry, { cancelled = true }, true)
    end
  end)
end

local function activate_native(manager, entry)
  local request = entry.request
  if request.method == "select" and (type(request.options) ~= "table" or #request.options == 0) then
    finish(manager, entry, { cancelled = true }, true)
    return
  end
  entry.surface = surface.open(request, function(response)
    finish(manager, entry, response, true)
  end, function()
    local response = request.method == "confirm" and { confirmed = false } or { cancelled = true }
    finish(manager, entry, response, true)
  end)
end

advance = function(manager)
  if manager.active or manager.discarding then
    return
  end
  local entry = table.remove(manager.queue, 1)
  if not entry then
    return
  end
  manager.active = entry
  if entry.permission then
    activate_permission(manager, entry)
  else
    activate_native(manager, entry)
  end
end

local function enqueue(client, request, handlers)
  if type(request.id) ~= "string" or request.id == "" then
    return
  end
  local manager = manager_for(client)
  if manager.by_id[request.id] then
    return
  end
  local entry = {
    request = request,
    handlers = handlers or {},
    permission = request.method == "select"
      and type(handlers) == "table"
      and type(handlers.permission_select) == "function"
      and permission_select(request),
    finished = false,
  }
  manager.by_id[request.id] = entry
  table.insert(manager.queue, entry)
  advance(manager)
end

function M.handle(client, request, handlers)
  local set_editor_text = type(handlers) == "function" and handlers or handlers and handlers.set_editor_text
  local set_status = type(handlers) == "table" and handlers.set_status or nil
  local set_widget = type(handlers) == "table" and handlers.set_widget or nil
  local set_title = type(handlers) == "table" and handlers.set_title or nil
  local method = request.method
  if method == "select" or method == "confirm" or method == "input" or method == "editor" then
    enqueue(client, request, handlers)
  elseif method == "notify" then
    local levels = {
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
      error = vim.log.levels.ERROR,
    }
    vim.notify(request.message or "", levels[request.notifyType] or vim.log.levels.INFO, { title = "Pi" })
  elseif method == "set_editor_text" and set_editor_text then
    set_editor_text(request.text or "")
  elseif method == "setStatus" and set_status then
    set_status(request.statusKey, request.statusText)
  elseif method == "setWidget" and set_widget then
    set_widget(request.widgetKey, request.widgetLines, request.widgetPlacement)
  elseif method == "setTitle" and set_title then
    set_title(request.title)
  end
end

function M.cancel(client, id)
  local manager = managers[client]
  local entry = manager and manager.by_id[id] or nil
  if not entry then
    return false
  end
  return finish(manager, entry, nil, false)
end

function M.discard(client)
  local manager = managers[client]
  if not manager then
    return
  end
  managers[client] = nil
  manager.discarding = true
  local entries = {}
  for _, entry in pairs(manager.by_id) do
    table.insert(entries, entry)
  end
  manager.by_id = {}
  manager.queue = {}
  manager.active = nil
  for _, entry in ipairs(entries) do
    entry.finished = true
    if entry.surface then
      entry.surface:close()
      entry.surface = nil
    elseif entry.cancel_external then
      entry.cancel_external()
    end
  end
end

return M
