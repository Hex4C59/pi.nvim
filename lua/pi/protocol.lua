local M = {}

local Parser = {}
Parser.__index = Parser

function Parser.new(opts)
  opts = opts or {}
  return setmetatable({
    buffer = "",
    parts = {},
    frame_bytes = 0,
    discarding = false,
    max_frame_bytes = opts.max_frame_bytes or (10 * 1024 * 1024),
    on_message = assert(opts.on_message, "on_message is required"),
    on_error = opts.on_error or function() end,
  }, Parser)
end

function Parser:_reset_frame()
  self.parts = {}
  self.frame_bytes = 0
  self.discarding = false
  self.buffer = ""
end

function Parser:_append(part)
  if part == "" or self.discarding then
    return
  end
  local next_size = self.frame_bytes + #part
  if next_size > self.max_frame_bytes then
    local preview = table.concat(self.parts)
    local remaining = math.max(0, self.max_frame_bytes - #preview)
    self.on_error("RPC frame exceeded maximum size", preview .. part:sub(1, remaining))
    self.parts = {}
    self.frame_bytes = 0
    self.discarding = true
    return
  end
  table.insert(self.parts, part)
  self.frame_bytes = next_size
end

function Parser:_finish_frame()
  if self.discarding then
    self:_reset_frame()
    return
  end
  local line = table.concat(self.parts)
  self:_reset_frame()
  self:_consume(line)
end

function Parser:_decode(line)
  if line == "" then
    return
  end

  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    self.on_error(("invalid RPC JSON: %s"):format(message), line)
    return
  end
  if type(message) ~= "table" then
    self.on_error("RPC frame must decode to an object", line)
    return
  end
  self.on_message(message, #line)
end

function Parser:_consume(line)
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if #line > self.max_frame_bytes then
    self.on_error("RPC frame exceeded maximum size", line)
    return
  end
  self:_decode(line)
end

function Parser:push(chunk)
  if not chunk or chunk == "" then
    return
  end

  local offset = 1
  while offset <= #chunk do
    local newline = chunk:find("\n", offset, true)
    if newline then
      self:_append(chunk:sub(offset, newline - 1))
      self:_finish_frame()
      offset = newline + 1
    else
      self:_append(chunk:sub(offset))
      break
    end
  end
end

function Parser:finish()
  -- Keep accepting direct buffer assignment for callers using the old parser state.
  if self.buffer ~= "" then
    self:_append(self.buffer)
    self.buffer = ""
  end
  if self.discarding then
    self:_reset_frame()
    return
  end
  if self.frame_bytes == 0 then
    return
  end
  self:_finish_frame()
end

M.Parser = Parser
return M
