local M = {}

local pending = setmetatable({}, { __mode = "k" })
local editor_group = vim.api.nvim_create_augroup("PiNvimExtensionEditors", { clear = false })

local function client_pending(client)
  local requests = pending[client]
  if not requests then
    requests = {}
    pending[client] = requests
  end
  return requests
end

local function cancel(client, id)
  local requests = client_pending(client)
  if requests[id] ~= true then
    return
  end
  requests[id] = nil
  client:respond_ui(id, { cancelled = true })
end

local function respond_once(client, id, response)
  local requests = client_pending(client)
  if requests[id] ~= true then
    return
  end
  requests[id] = nil
  client:respond_ui(id, response)
end

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

local function editor(client, request)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(request.prefill or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.max(40, math.floor(vim.o.columns * 0.65))
  local height = math.max(8, math.min(#lines + 4, math.floor(vim.o.lines * 0.6)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = request.title or "Pi input",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })

  local finished = false
  local autocmds = {}
  local function close(response)
    if finished then
      return
    end
    finished = true
    for _, autocmd in ipairs(autocmds) do
      pcall(vim.api.nvim_del_autocmd, autocmd)
    end
    autocmds = {}
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    respond_once(client, request.id, response)
  end

  local function submit()
    close({ value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") })
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function()
    close({ cancelled = true })
  end, { buffer = buf, silent = true })

  table.insert(
    autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      group = editor_group,
      pattern = tostring(win),
      once = true,
      callback = function()
        close({ cancelled = true })
      end,
    })
  )
  table.insert(
    autocmds,
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      group = editor_group,
      buffer = buf,
      once = true,
      callback = function()
        close({ cancelled = true })
      end,
    })
  )
end

function M.handle(client, request, handlers)
  local set_editor_text = type(handlers) == "function" and handlers or handlers and handlers.set_editor_text
  local confirm = type(handlers) == "table" and handlers.confirm or nil
  local show_permission = type(handlers) == "table" and handlers.permission_select or nil
  local set_status = type(handlers) == "table" and handlers.set_status or nil
  local set_widget = type(handlers) == "table" and handlers.set_widget or nil
  local set_title = type(handlers) == "table" and handlers.set_title or nil
  local method = request.method
  if request.id and (method == "select" or method == "confirm" or method == "input" or method == "editor") then
    client_pending(client)[request.id] = true
  end
  if method == "select" then
    if show_permission and permission_select(request) then
      show_permission(permission_request(request), function(choice)
        if type(choice) ~= "string" then
          cancel(client, request.id)
        else
          respond_once(client, request.id, { value = choice })
        end
      end)
    else
      vim.ui.select(request.options or {}, { prompt = request.title or "Pi" }, function(choice)
        if choice == nil then
          cancel(client, request.id)
        else
          respond_once(client, request.id, { value = choice })
        end
      end)
    end
  elseif method == "confirm" then
    if confirm then
      confirm(request, function(confirmed)
        respond_once(client, request.id, { confirmed = confirmed == true })
      end)
    else
      respond_once(client, request.id, { confirmed = false })
    end
  elseif method == "input" then
    vim.ui.input({ prompt = (request.title or "Pi") .. ": ", default = "" }, function(value)
      if value == nil then
        cancel(client, request.id)
      else
        respond_once(client, request.id, { value = value })
      end
    end)
  elseif method == "editor" then
    editor(client, request)
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

function M.discard(client)
  pending[client] = nil
end

return M
