local M = {}
local BoundedText = {}
BoundedText.__index = BoundedText

local function count_newlines(text, first, last)
  first = first or 1
  last = last or #text
  local count = 0
  local offset = first
  while offset <= last do
    local newline = text:find("\n", offset, true)
    if not newline or newline > last then
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

local function generation(bytes)
  local level = 0
  while bytes >= 2 do
    bytes = math.floor(bytes / 2)
    level = level + 1
  end
  return level
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
    _target_block_bytes = math.max(256, math.ceil(opts.max_bytes / opts.max_chunks)),
    _chunks = {},
    _head = 1,
    _head_offset = 1,
    _tail = 0,
    _bytes = 0,
    _newlines = 0,
    _ends_newline = false,
    _omitted_bytes = 0,
    _omitted_newlines = 0,
    _leading_partial = false,
    _copied_bytes = 0,
  }, BoundedText)
end

function BoundedText:_chunk_count()
  return math.max(0, self._tail - self._head + 1)
end

function BoundedText:_reset_chunks()
  self._chunks = {}
  self._head = 1
  self._head_offset = 1
  self._tail = 0
  self._ends_newline = false
end

function BoundedText:_rebase_chunks()
  if self._head <= 4096 then
    return
  end
  local chunks = {}
  for index = self._head, self._tail do
    chunks[#chunks + 1] = self._chunks[index]
  end
  self._chunks = chunks
  self._tail = #chunks
  self._head = 1
end

function BoundedText:_record_omitted_range(text, first, last, remove_retained)
  if first > last then
    return 0
  end
  local bytes = last - first + 1
  local newlines = count_newlines(text, first, last)
  self._omitted_bytes = self._omitted_bytes + bytes
  self._omitted_newlines = self._omitted_newlines + newlines
  self._leading_partial = text:sub(last, last) ~= "\n"
  if remove_retained then
    self._bytes = self._bytes - bytes
    self._newlines = self._newlines - newlines
  end
  return newlines
end

function BoundedText:_materialize_head(force)
  if self._head > self._tail or self._head_offset == 1 then
    return
  end
  local block = self._chunks[self._head]
  local consumed = self._head_offset - 1
  if not force and consumed * 2 < #block.text then
    return
  end
  local suffix = block.text:sub(self._head_offset)
  self._copied_bytes = self._copied_bytes + #suffix
  block.text = suffix
  block.level = generation(#suffix)
  self._head_offset = 1
end

function BoundedText:_drop_prefix(bytes, utf8_safe)
  local remaining = math.max(0, bytes)
  while remaining > 0 and self._head <= self._tail do
    local block = self._chunks[self._head]
    local first = self._head_offset
    local available = #block.text - first + 1
    if remaining >= available then
      self._chunks[self._head] = nil
      self._head = self._head + 1
      self._head_offset = 1
      remaining = remaining - available
      self:_record_omitted_range(block.text, first, #block.text, true)
    else
      local cut = first + remaining
      if utf8_safe then
        while cut <= #block.text do
          local byte = block.text:byte(cut)
          if not byte or byte < 0x80 or byte > 0xBF then
            break
          end
          cut = cut + 1
        end
      end
      local removed_newlines = self:_record_omitted_range(block.text, first, cut - 1, true)
      block.newlines = block.newlines - removed_newlines
      self._head_offset = cut
      remaining = 0
      self:_materialize_head(false)
    end
  end
  if self._head > self._tail then
    self:_reset_chunks()
  else
    self:_rebase_chunks()
  end
end

function BoundedText:_drop_lines(lines)
  local remaining = lines
  while remaining > 0 and self._head <= self._tail do
    local block = self._chunks[self._head]
    local first = self._head_offset
    local offset = first
    local found = 0
    local newline
    while found < remaining do
      newline = block.text:find("\n", offset, true)
      if not newline then
        break
      end
      found = found + 1
      offset = newline + 1
    end
    if found == 0 then
      self:_drop_prefix(#block.text - first + 1, false)
    else
      self:_drop_prefix(offset - first, false)
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

function BoundedText:_merge_pair(index)
  if index == self._head and self._head_offset > 1 then
    self:_materialize_head(true)
  end
  local left = self._chunks[index]
  local right = self._chunks[index + 1]
  local text = left.text .. right.text
  self._copied_bytes = self._copied_bytes + #text
  self._chunks[index] = {
    text = text,
    newlines = left.newlines + right.newlines,
    level = generation(#text),
  }
  for cursor = index + 1, self._tail - 1 do
    self._chunks[cursor] = self._chunks[cursor + 1]
  end
  self._chunks[self._tail] = nil
  self._tail = self._tail - 1
end

function BoundedText:_balance_tail()
  while self:_chunk_count() >= 2 do
    local left = self._chunks[self._tail - 1]
    local right = self._chunks[self._tail]
    if left.level ~= right.level then
      break
    end
    self:_merge_pair(self._tail - 1)
  end
end

function BoundedText:_enforce_chunk_limit()
  while self:_chunk_count() > self.max_chunks do
    local best_index = self._head
    local best_size = math.huge
    for index = self._head, self._tail - 1 do
      local left_size = #self._chunks[index].text - (index == self._head and self._head_offset - 1 or 0)
      local size = left_size + #self._chunks[index + 1].text
      if size < best_size then
        best_index = index
        best_size = size
      end
    end
    self:_merge_pair(best_index)
  end
end

function BoundedText:_push_block(text)
  self._tail = self._tail + 1
  self._chunks[self._tail] = {
    text = text,
    newlines = count_newlines(text),
    level = generation(#text),
  }
  self:_balance_tail()
  self:_enforce_chunk_limit()
end

function BoundedText:_append_blocks(delta)
  local offset = 1
  while offset <= #delta do
    local last = math.min(#delta, offset + self._target_block_bytes - 1)
    if last < #delta then
      while last >= offset do
        local next_byte = delta:byte(last + 1)
        if not next_byte or next_byte < 0x80 or next_byte > 0xBF then
          break
        end
        last = last - 1
      end
    end
    if last < offset then
      last = math.min(#delta, offset + self._target_block_bytes + 3)
      while last < #delta do
        local next_byte = delta:byte(last + 1)
        if not next_byte or next_byte < 0x80 or next_byte > 0xBF then
          break
        end
        last = last + 1
      end
    end
    local block
    if offset == 1 and last == #delta then
      block = delta
    else
      block = delta:sub(offset, last)
      self._copied_bytes = self._copied_bytes + #block
    end
    self:_push_block(block)
    offset = last + 1
  end
end

function BoundedText:append(delta)
  if delta == nil or delta == "" then
    return
  end
  if type(delta) ~= "string" then
    delta = tostring(delta)
  end

  if #delta > self.max_bytes then
    self:_drop_prefix(self._bytes, false)
    local cut = #delta - self.max_bytes + 1
    while cut <= #delta do
      local byte = delta:byte(cut)
      if not byte or byte < 0x80 or byte > 0xBF then
        break
      end
      cut = cut + 1
    end
    self:_record_omitted_range(delta, 1, cut - 1, false)
    delta = delta:sub(cut)
    self._copied_bytes = self._copied_bytes + #delta
    if delta == "" then
      self._ends_newline = false
      return
    end
  end

  self._bytes = self._bytes + #delta
  self._newlines = self._newlines + count_newlines(delta)
  self._ends_newline = delta:sub(-1) == "\n"
  self:_append_blocks(delta)

  local excess_lines = self:_line_count() - self.max_lines
  if excess_lines > 0 then
    self:_drop_lines(excess_lines)
  end
  if self._bytes > self.max_bytes then
    self:_drop_prefix(self._bytes - self.max_bytes, true)
  end
end

function BoundedText:text()
  local chunks = {}
  for index = self._head, self._tail do
    local text = self._chunks[index].text
    chunks[#chunks + 1] = index == self._head and text:sub(self._head_offset) or text
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
    copied_bytes = self._copied_bytes,
  }
end

M.BoundedText = BoundedText
return M
