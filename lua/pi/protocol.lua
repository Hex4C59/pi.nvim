local M = {}

local Parser = {}
Parser.__index = Parser

function Parser.new(opts)
  opts = opts or {}
  return setmetatable({
    buffer = "",
    max_frame_bytes = opts.max_frame_bytes or (10 * 1024 * 1024),
    on_message = assert(opts.on_message, "on_message is required"),
    on_error = opts.on_error or function() end,
  }, Parser)
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
  self.on_message(message)
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

  self.buffer = self.buffer .. chunk
  while true do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end

    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    self:_consume(line)
  end

  if #self.buffer > self.max_frame_bytes then
    local dropped = self.buffer
    self.buffer = ""
    self.on_error("RPC frame exceeded maximum size", dropped)
  end
end

function Parser:finish()
  if self.buffer == "" then
    return
  end
  local line = self.buffer
  self.buffer = ""
  self:_consume(line)
end

M.Parser = Parser
return M
