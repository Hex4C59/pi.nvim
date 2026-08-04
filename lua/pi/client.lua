local config = require("pi.config")
local Parser = require("pi.protocol").Parser

local M = {}
local Client = {}
Client.__index = Client
local max_dispatch_batch = 256

function Client.new(root)
  local max_frame_bytes = config.get().output.rpc_queue_max_bytes
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
    dispatch_queue = {},
    dispatch_head = 1,
    dispatch_tail = 0,
    dispatch_count = 0,
    dispatch_bytes = 0,
    dispatch_scheduled = false,
    dispatch_overload = nil,
    max_frame_bytes = max_frame_bytes,
  }, Client)

  self.parser = Parser.new({
    max_frame_bytes = max_frame_bytes,
    on_message = function(message, frame_bytes)
      self:_enqueue_dispatch("message", message, nil, frame_bytes)
    end,
    on_error = function(err, frame)
      self:_enqueue_dispatch("error", err, frame, #(frame or ""))
    end,
  })
  return self
end

function Client:_enqueue_dispatch(kind, value, frame, bytes)
  if self.dispatch_overload then
    return
  end
  bytes = math.max(0, math.floor(tonumber(bytes) or 0))
  local output = config.get().output
  if
    self.dispatch_count >= output.rpc_queue_max_messages or self.dispatch_bytes + bytes > output.rpc_queue_max_bytes
  then
    self.dispatch_overload = ("RPC dispatch queue exceeded %d messages or %d bytes; stopping Pi to preserve client state"):format(
      output.rpc_queue_max_messages,
      output.rpc_queue_max_bytes
    )
  else
    self.dispatch_tail = self.dispatch_tail + 1
    self.dispatch_queue[self.dispatch_tail] = { kind = kind, value = value, frame = frame, bytes = bytes }
    self.dispatch_count = self.dispatch_count + 1
    self.dispatch_bytes = self.dispatch_bytes + bytes
  end
  if self.dispatch_scheduled then
    return
  end
  self.dispatch_scheduled = true
  vim.schedule(function()
    self:_drain_dispatch()
  end)
end

function Client:_drain_dispatch()
  if self.dispatch_overload then
    local message = self.dispatch_overload
    self.dispatch_queue = {}
    self.dispatch_head = 1
    self.dispatch_tail = 0
    self.dispatch_count = 0
    self.dispatch_bytes = 0
    self.dispatch_scheduled = false
    self:_emit({ type = "client_error", error = message })
    self:stop()
    return
  end
  local processed = 0
  while self.dispatch_count > 0 and processed < max_dispatch_batch do
    local entry = self.dispatch_queue[self.dispatch_head]
    self.dispatch_queue[self.dispatch_head] = nil
    self.dispatch_head = self.dispatch_head + 1
    self.dispatch_count = self.dispatch_count - 1
    self.dispatch_bytes = math.max(0, self.dispatch_bytes - (entry.bytes or 0))
    processed = processed + 1
    local ok, err = pcall(function()
      if entry.kind == "message" then
        self:_handle(entry.value)
      else
        self:_emit({ type = "client_error", error = entry.value, frame = entry.frame })
      end
    end)
    if not ok then
      self:_emit({ type = "client_error", error = "RPC dispatch failed: " .. tostring(err) })
    end
  end

  if self.dispatch_count == 0 then
    self.dispatch_queue = {}
    self.dispatch_head = 1
    self.dispatch_tail = 0
    self.dispatch_bytes = 0
    self.dispatch_scheduled = false
    return
  end
  vim.schedule(function()
    self:_drain_dispatch()
  end)
end

function Client:on_event(listener)
  table.insert(self.listeners, listener)
  local subscribed = true
  return function()
    if not subscribed then
      return false
    end
    subscribed = false
    for index, candidate in ipairs(self.listeners) do
      if candidate == listener then
        table.remove(self.listeners, index)
        return true
      end
    end
    return false
  end
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
  self.dispatch_overload = nil
  self:_emit({ type = "client_state", state = self.state })

  local ok, process_or_error = pcall(vim.system, cmd, {
    cwd = self.root,
    stdin = true,
    text = false,
    stdout = function(err, chunk)
      if err then
        self:_enqueue_dispatch("error", err)
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
  if #encoded > self.max_frame_bytes then
    return false, ("RPC request frame is too large (%d bytes; limit %d)"):format(#encoded, self.max_frame_bytes)
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
    message._pi_request_matched = pending ~= nil
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
  if self.stopping or not self:is_running() then
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
