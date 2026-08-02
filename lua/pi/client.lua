local config = require("pi.config")
local Parser = require("pi.protocol").Parser

local M = {}
local Client = {}
Client.__index = Client

function Client.new(root)
  local self = setmetatable({
    root = root,
    process = nil,
    state = "stopped",
    session = {},
    next_id = 0,
    pending = {},
    listeners = {},
    stderr = {},
    stopping = false,
  }, Client)

  self.parser = Parser.new({
    on_message = function(message)
      vim.schedule(function()
        self:_handle(message)
      end)
    end,
    on_error = function(err, frame)
      vim.schedule(function()
        self:_emit({ type = "client_error", error = err, frame = frame })
      end)
    end,
  })
  return self
end

function Client:on_event(listener)
  table.insert(self.listeners, listener)
end

function Client:_emit(event)
  for _, listener in ipairs(self.listeners) do
    local ok, err = pcall(listener, event)
    if not ok then
      vim.notify("pi.nvim event handler failed: " .. err, vim.log.levels.ERROR)
    end
  end
end

function Client:is_running()
  return self.process ~= nil and not self.process:is_closing()
end

function Client:start()
  if self:is_running() then
    return true
  end

  local cmd = config.command(self.root)
  self.state = "starting"
  self.stopping = false
  self:_emit({ type = "client_state", state = self.state })

  local ok, process_or_error = pcall(vim.system, cmd, {
    cwd = self.root,
    stdin = true,
    text = false,
    stdout = function(err, chunk)
      if err then
        vim.schedule(function()
          self:_emit({ type = "client_error", error = err })
        end)
        return
      end
      if chunk then
        self.parser:push(chunk)
      else
        self.parser:finish()
      end
    end,
    stderr = function(_, chunk)
      if not chunk or chunk == "" then
        return
      end
      table.insert(self.stderr, chunk)
      if #self.stderr > 20 then
        table.remove(self.stderr, 1)
      end
    end,
  }, function(result)
    vim.schedule(function()
      self.process = nil
      local was_stopping = self.stopping
      self.stopping = false
      self.state = "stopped"
      for id, request in pairs(self.pending) do
        self.pending[id] = nil
        if request.callback and not was_stopping then
          request.callback(false, nil, "Pi process exited")
        end
      end
      self:_emit({
        type = "client_exit",
        code = result.code,
        signal = result.signal,
        expected = was_stopping,
        stderr = table.concat(self.stderr),
      })
    end)
  end)

  if not ok then
    self.state = "stopped"
    self:_emit({ type = "client_error", error = process_or_error })
    return false
  end

  self.process = process_or_error
  self:request("get_state", {}, function(success, data, err)
    if not success then
      self:_emit({ type = "client_error", error = err or "Unable to read Pi state" })
      return
    end
    self.session = data or {}
    self.state = self.session.isStreaming and "streaming" or "idle"
    self:_emit({ type = "client_state", state = self.state, data = self.session })

    self:request("get_messages", {}, function(messages_ok, messages)
      if messages_ok then
        self:_emit({ type = "history", messages = messages.messages or {} })
      end
    end)
  end)
  return true
end

function Client:_raw_send(message)
  if not self:is_running() and not self:start() then
    return false, "Unable to start Pi"
  end

  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    return false, encoded
  end
  local wrote, err = pcall(self.process.write, self.process, encoded .. "\n")
  if not wrote then
    return false, err
  end
  return true
end

function Client:request(command, payload, callback, timeout)
  self.next_id = self.next_id + 1
  local id = ("nvim-%d"):format(self.next_id)
  local message = vim.tbl_extend("force", payload or {}, { id = id, type = command })
  self.pending[id] = { command = command, callback = callback }

  local sent, err = self:_raw_send(message)
  if not sent then
    self.pending[id] = nil
    if callback then
      callback(false, nil, err)
    end
    return nil
  end

  local wait = timeout == nil and config.get().request_timeout or timeout
  if wait and wait > 0 then
    vim.defer_fn(function()
      local pending = self.pending[id]
      if not pending then
        return
      end
      self.pending[id] = nil
      if pending.callback then
        pending.callback(false, nil, ("RPC request timed out: %s"):format(command))
      end
    end, wait)
  end
  return id
end

function Client:respond_ui(id, response)
  return self:_raw_send(vim.tbl_extend("force", response or {}, {
    type = "extension_ui_response",
    id = id,
  }))
end

function Client:_handle(message)
  if message.type == "response" then
    local pending = message.id and self.pending[message.id] or nil
    if pending then
      self.pending[message.id] = nil
      if pending.callback then
        pending.callback(message.success == true, message.data, message.error)
      end
    end
  elseif message.type == "agent_start" then
    self.state = "streaming"
  elseif message.type == "agent_settled" then
    self.state = "idle"
  elseif message.type == "compaction_start" then
    self.state = "compacting"
  end

  self:_emit(message)
end

function Client:stop()
  if not self:is_running() then
    return
  end
  self.stopping = true
  if self.state == "streaming" or self.state == "compacting" then
    self:_raw_send({ type = "abort" })
  end
  self.process:write(nil)
  self.process:kill("sigterm")
end

M.Client = Client
return M
