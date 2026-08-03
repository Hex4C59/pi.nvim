local M = {}
M.__index = M

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(timer.stop, timer)
  if not timer:is_closing() then
    pcall(timer.close, timer)
  end
end

local function close_entry(entry)
  if not entry then
    return
  end
  close_timer(entry.timer)
  entry.timer = nil
  if entry.handle and type(entry.handle.close) == "function" then
    pcall(entry.handle.close, entry.handle)
  end
end

local function signature(placement)
  return table.concat({
    placement.path or "",
    tostring(placement.row or 0),
    tostring(placement.col or 0),
    tostring(placement.width or 0),
    tostring(placement.height or 0),
    tostring(placement.range_height or placement.height or 0),
    tostring(placement.inline ~= false),
    tostring(placement.conceal == true),
  }, "\0")
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    handles = {},
    auto_resize = opts.auto_resize ~= false,
    timeout_ms = opts.timeout_ms or 10000,
    snacks = opts.snacks,
  }, M)
end

function M:_load()
  if self.snacks then
    return self.snacks
  end
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return nil, "snacks.nvim is not installed"
  end
  self.snacks = snacks
  return snacks
end

function M:_image()
  local snacks, load_err = self:_load()
  if not snacks then
    return nil, load_err
  end
  if snacks.config and snacks.config.image and snacks.config.image.enabled ~= true then
    return nil, "snacks.image is not enabled"
  end
  local ok, image = pcall(function()
    return snacks.image
  end)
  if not ok or type(image) ~= "table" then
    return nil, "snacks.image could not be loaded"
  end
  if not image.placement or type(image.placement.new) ~= "function" then
    return nil, "snacks.image placement API is unavailable"
  end
  return image
end

function M:probe(callback)
  local image, image_err = self:_image()
  if not image then
    callback(false, image_err)
    return
  end

  local completed = false
  local function finish(available, reason)
    if completed then
      return
    end
    completed = true
    callback(available == true, reason)
  end
  local function supported(terminal)
    local available = type(terminal) == "table" and terminal.supported == true
    if not available and type(image.supports_terminal) == "function" then
      local ok, result = pcall(image.supports_terminal)
      available = ok and result == true
    end
    finish(available, available and nil or "the current terminal does not support Kitty graphics")
  end

  if image.terminal and type(image.terminal.detect) == "function" then
    local ok, err = pcall(image.terminal.detect, supported)
    if not ok then
      finish(false, "terminal capability detection failed: " .. tostring(err))
    end
  else
    supported()
  end
end

function M:_watch(buf, key, entry, on_failure)
  if self.timeout_ms <= 0 or not entry.handle or type(entry.handle.ready) ~= "function" then
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  entry.timer = timer
  timer:start(
    self.timeout_ms,
    0,
    vim.schedule_wrap(function()
      close_timer(timer)
      entry.timer = nil
      local current = self.handles[buf] and self.handles[buf][key]
      if current ~= entry then
        return
      end
      local ok, ready = pcall(entry.handle.ready, entry.handle)
      if ok and ready then
        return
      end
      self.handles[buf][key] = nil
      local failed = entry.handle.img
        and type(entry.handle.img.failed) == "function"
        and select(2, pcall(entry.handle.img.failed, entry.handle.img)) == true
      local conversion = entry.handle.img and entry.handle.img._convert
      if conversion and type(conversion.abort) == "function" then
        pcall(conversion.abort, conversion)
      end
      close_entry(entry)
      on_failure(entry.descriptor, failed and "image conversion failed" or "image conversion timed out")
    end)
  )
end

function M:_create(image, buf, descriptor, on_failure)
  local range_height = descriptor.range_height or descriptor.height
  local opts = {
    pos = { descriptor.row + 1, descriptor.col },
    range = {
      descriptor.row + 1,
      descriptor.col,
      descriptor.row + range_height,
      descriptor.col,
    },
    inline = descriptor.inline ~= false,
    conceal = descriptor.conceal == true,
    width = descriptor.width,
    height = descriptor.height,
    auto_resize = self.auto_resize,
  }
  local ok, handle = pcall(image.placement.new, buf, descriptor.path, opts)
  if not ok or type(handle) ~= "table" then
    on_failure(descriptor, "terminal image placement failed: " .. tostring(handle))
    return nil
  end
  local entry = {
    descriptor = descriptor,
    handle = handle,
    signature = signature(descriptor),
  }
  self:_watch(buf, descriptor.key, entry, on_failure)
  return entry
end

function M:sync(buf, _, placements, on_failure)
  if not vim.api.nvim_buf_is_valid(buf) then
    self:clear(buf)
    return false, "image buffer is no longer valid"
  end
  local image, image_err = self:_image()
  if not image then
    self:clear(buf)
    return false, image_err
  end

  local current = self.handles[buf] or {}
  local next_handles = {}
  for _, descriptor in ipairs(placements or {}) do
    local existing = current[descriptor.key]
    if existing and existing.signature == signature(descriptor) then
      next_handles[descriptor.key] = existing
    else
      local created = self:_create(image, buf, descriptor, on_failure)
      if created then
        next_handles[descriptor.key] = created
      end
      close_entry(existing)
    end
  end
  for key, entry in pairs(current) do
    if not next_handles[key] then
      close_entry(entry)
    end
  end
  self.handles[buf] = next_handles
  return true
end

function M:clear(buf)
  local buffers = buf and { buf } or vim.tbl_keys(self.handles)
  for _, target in ipairs(buffers) do
    for _, entry in pairs(self.handles[target] or {}) do
      close_entry(entry)
    end
    self.handles[target] = nil
  end
end

return M
