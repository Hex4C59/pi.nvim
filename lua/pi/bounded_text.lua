local M = {}
local BoundedText = {}
BoundedText.__index = BoundedText

local function count_newlines(text)
  local count = 0
  local offset = 1
  while true do
    local newline = text:find("\n", offset, true)
    if not newline then
      break
    end
    count = count + 1
    offset = newline + 1
  end
  return count
end

local function validate_limit(name, value)
  if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 then
    error(("BoundedText %s must be a positive integer"):format(name))
  end
end

function BoundedText.new(opts)
  opts = opts or {}
  validate_limit("max_bytes", opts.max_bytes)
  validate_limit("max_lines", opts.max_lines)
  validate_limit("max_chunks", opts.max_chunks)
  return setmetatable({
    max_bytes = opts.max_bytes,
    max_lines = opts.max_lines,
    max_chunks = opts.max_chunks,
    _chunks = {},
    _head = 1,
    _tail = 0,
    _bytes = 0,
    _newlines = 0,
    _ends_newline = false,
    _omitted_bytes = 0,
    _omitted_newlines = 0,
    _leading_partial = false,
  }, BoundedText)
end

function BoundedText:_chunk_count()
  return math.max(0, self._tail - self._head + 1)
end

function BoundedText:_record_removed(text)
  if text == "" then
    return
  end
  local newlines = count_newlines(text)
  self._omitted_bytes = self._omitted_bytes + #text
  self._omitted_newlines = self._omitted_newlines + newlines
  self._newlines = self._newlines - newlines
  self._bytes = self._bytes - #text
  self._leading_partial = text:sub(-1) ~= "\n"
end

function BoundedText:_drop_prefix(bytes, utf8_safe)
  local remaining = math.max(0, bytes)
  while remaining > 0 and self._head <= self._tail do
    local chunk = self._chunks[self._head]
    if remaining >= #chunk then
      self._chunks[self._head] = nil
      self._head = self._head + 1
      remaining = remaining - #chunk
      self:_record_removed(chunk)
    else
      local cut = remaining + 1
      if utf8_safe then
        while cut <= #chunk do
          local byte = chunk:byte(cut)
          if not byte or byte < 0x80 or byte > 0xBF then
            break
          end
          cut = cut + 1
        end
      end
      local removed = chunk:sub(1, cut - 1)
      self:_record_removed(removed)
      if cut > #chunk then
        self._chunks[self._head] = nil
        self._head = self._head + 1
      else
        self._chunks[self._head] = chunk:sub(cut)
      end
      remaining = 0
    end
  end
  if self._head > self._tail then
    self._head = 1
    self._tail = 0
    self._chunks = {}
    self._ends_newline = false
  end
end

function BoundedText:_drop_lines(lines)
  local remaining = lines
  while remaining > 0 and self._head <= self._tail do
    local chunk = self._chunks[self._head]
    local offset = 1
    local newline
    for _ = 1, remaining do
      newline = chunk:find("\n", offset, true)
      if not newline then
        break
      end
      offset = newline + 1
    end
    local found = count_newlines(chunk:sub(1, offset - 1))
    if found == 0 then
      self:_drop_prefix(#chunk, false)
    else
      self:_drop_prefix(offset - 1, false)
      remaining = remaining - found
    end
  end
end

function BoundedText:_line_count()
  if self._bytes == 0 then
    return 0
  end
  return self._newlines + (self._ends_newline and 0 or 1)
end

function BoundedText:_compact_chunks()
  while self:_chunk_count() > self.max_chunks do
    local first = self._chunks[self._head]
    local second = self._chunks[self._head + 1]
    self._chunks[self._head] = nil
    self._chunks[self._head + 1] = first .. second
    self._head = self._head + 1
  end
end

function BoundedText:append(delta)
  if delta == nil or delta == "" then
    return
  end
  if type(delta) ~= "string" then
    delta = tostring(delta)
  end
  self._tail = self._tail + 1
  self._chunks[self._tail] = delta
  self._bytes = self._bytes + #delta
  self._newlines = self._newlines + count_newlines(delta)
  self._ends_newline = delta:sub(-1) == "\n"

  local excess_lines = self:_line_count() - self.max_lines
  if excess_lines > 0 then
    self:_drop_lines(excess_lines)
  end
  if self._bytes > self.max_bytes then
    self:_drop_prefix(self._bytes - self.max_bytes, true)
  end
  self:_compact_chunks()
end

function BoundedText:text()
  local chunks = {}
  for index = self._head, self._tail do
    chunks[#chunks + 1] = self._chunks[index]
  end
  return table.concat(chunks)
end

function BoundedText:stats()
  local omitted_lines = self._omitted_newlines + (self._leading_partial and 1 or 0)
  return {
    retained_bytes = self._bytes,
    retained_lines = self:_line_count(),
    omitted_bytes = self._omitted_bytes,
    omitted_lines = omitted_lines,
    truncated = self._omitted_bytes > 0,
    chunks = self:_chunk_count(),
  }
end

M.BoundedText = BoundedText
return M
