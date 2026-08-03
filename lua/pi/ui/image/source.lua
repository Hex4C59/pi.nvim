local config = require("pi.config")

local M = {}
local image_cache_dir
local cache_cleaned = false

local mime_extensions = {
  ["image/png"] = ".png",
  ["image/jpeg"] = ".jpg",
  ["image/webp"] = ".webp",
  ["image/gif"] = ".gif",
  ["image/bmp"] = ".bmp",
}

function M.config()
  return config.get().images or {}
end

function M.mime_type(block)
  local mime = block and (block.mimeType or block.mime_type)
  if not mime and type(block and block.source) == "table" then
    mime = block.source.mimeType or block.source.media_type or block.source.mediaType
  end
  return (mime or "image/unknown"):match("^[^;]+") or "image/unknown"
end

function M.base64_data(block)
  if type(block) ~= "table" then
    return nil
  end
  if type(block.data) == "string" then
    return block.data
  end
  if type(block.source) == "table" and type(block.source.data) == "string" then
    return block.source.data
  end
end

local function cache_dir()
  if not image_cache_dir then
    image_cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "pi.nvim", "images")
    vim.fn.mkdir(image_cache_dir, "p")
    pcall(vim.uv.fs_chmod, image_cache_dir, 448)
  end
  return image_cache_dir
end

local function cleanup_cache()
  if cache_cleaned then
    return
  end
  cache_cleaned = true
  local maximum_age = (M.config().cache_max_age_days or 7) * 24 * 60 * 60
  local scanner = vim.uv.fs_scandir(cache_dir())
  if not scanner then
    return
  end
  local now = os.time()
  while true do
    local name, kind = vim.uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if kind == "file" and name:match("^[0-9a-f]+%.[%w]+$") then
      local path = vim.fs.joinpath(cache_dir(), name)
      local stat = vim.uv.fs_stat(path)
      local modified = stat and stat.mtime and stat.mtime.sec or now
      if now - modified > maximum_age then
        pcall(vim.uv.fs_unlink, path)
      end
    end
  end
end

local function read_file(path, maximum)
  local stat, stat_err = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, stat_err or "image path is not a readable file"
  end
  if stat.size <= 0 then
    return nil, "image file is empty"
  end
  if stat.size > maximum then
    return nil, ("image is too large (%d bytes; limit %d)"):format(stat.size, maximum)
  end
  local fd, open_err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, open_err or "unable to open image"
  end
  local bytes, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(bytes) ~= "string" or #bytes ~= stat.size then
    return nil, read_err or "unable to read complete image"
  end
  return bytes
end

local function write_private(path, bytes)
  local fd, err = vim.uv.fs_open(path, "w", 384)
  if not fd then
    return false, err
  end
  local written, write_err = vim.uv.fs_write(fd, bytes, 0)
  vim.uv.fs_close(fd)
  if written ~= #bytes then
    pcall(vim.uv.fs_unlink, path)
    return false, write_err or "short image cache write"
  end
  pcall(vim.uv.fs_chmod, path, 384)
  return true
end

local function be16(data, index)
  local a, b = data:byte(index, index + 1)
  return a and b and (a * 256 + b) or nil
end

local function be32(data, index)
  local a, b, c, d = data:byte(index, index + 3)
  return a and d and (a * 16777216 + b * 65536 + c * 256 + d) or nil
end

local function le16(data, index)
  local a, b = data:byte(index, index + 1)
  return a and b and (a + b * 256) or nil
end

local function le24(data, index)
  local a, b, c = data:byte(index, index + 2)
  return a and c and (a + b * 256 + c * 65536) or nil
end

local function le32(data, index)
  local a, b, c, d = data:byte(index, index + 3)
  return a and d and (a + b * 256 + c * 65536 + d * 16777216) or nil
end

local jpeg_size_markers = {
  [0xC0] = true,
  [0xC1] = true,
  [0xC2] = true,
  [0xC3] = true,
  [0xC5] = true,
  [0xC6] = true,
  [0xC7] = true,
  [0xC9] = true,
  [0xCA] = true,
  [0xCB] = true,
  [0xCD] = true,
  [0xCE] = true,
  [0xCF] = true,
}

local function jpeg_dimensions(data)
  if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
    return nil
  end
  local index = 3
  while index <= #data - 8 do
    while data:byte(index) == 0xFF do
      index = index + 1
    end
    local marker = data:byte(index)
    index = index + 1
    if not marker or marker == 0xD9 or marker == 0xDA then
      break
    end
    if marker ~= 0x01 and not (marker >= 0xD0 and marker <= 0xD8) then
      local length = be16(data, index)
      if not length or length < 2 or index + length - 1 > #data then
        return nil
      end
      if jpeg_size_markers[marker] then
        return be16(data, index + 5), be16(data, index + 3)
      end
      index = index + length
    end
  end
end

local function webp_dimensions(data)
  if #data < 30 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP" then
    return nil
  end
  local chunk = data:sub(13, 16)
  if chunk == "VP8X" then
    return (le24(data, 25) or -1) + 1, (le24(data, 28) or -1) + 1
  elseif chunk == "VP8L" and data:byte(21) == 0x2F then
    local b1, b2, b3, b4 = data:byte(22, 25)
    if b4 then
      return 1 + b1 + (b2 % 64) * 256, 1 + math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024
    end
  elseif chunk == "VP8 " and data:sub(24, 26) == "\157\001\042" then
    local width, height = le16(data, 27), le16(data, 29)
    return width and width % 16384 or nil, height and height % 16384 or nil
  end
end

function M.dimensions(data, mime)
  local width, height
  if mime == "image/png" and data:sub(1, 8) == "\137PNG\r\n\026\n" then
    width, height = be32(data, 17), be32(data, 21)
  elseif mime == "image/jpeg" then
    width, height = jpeg_dimensions(data)
  elseif mime == "image/gif" and (data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a") then
    width, height = le16(data, 7), le16(data, 9)
  elseif mime == "image/bmp" and data:sub(1, 2) == "BM" then
    width, height = le32(data, 19), le32(data, 23)
    if height and height >= 0x80000000 then
      height = 0x100000000 - height
    end
  elseif mime == "image/webp" then
    width, height = webp_dimensions(data)
  end
  if not width or not height or width < 1 or height < 1 then
    return nil, nil, "image dimensions are invalid or do not match the MIME type"
  end
  return width, height
end

function M.target_size(pixel_width, pixel_height, available_width, limits)
  local options = M.config()
  limits = limits or {}
  local maximum_width = limits.max_width or options.max_width or 72
  local width = math.max(1, math.min(maximum_width, math.floor(available_width or maximum_width)))
  local height = math.max(1, math.ceil(width * pixel_height / pixel_width / 2))
  local maximum_height = limits.max_height or options.max_height or 32
  if height > maximum_height then
    height = maximum_height
    width = math.max(1, math.floor(height * 2 * pixel_width / pixel_height))
  end
  return width, height
end

local function load(block)
  local mime = M.mime_type(block)
  local extension = mime_extensions[mime]
  if not extension then
    return nil, nil, mime, "image MIME type is not supported"
  end
  local maximum = M.config().max_bytes or 8 * 1024 * 1024
  local bytes, read_err
  if type(block.path) == "string" and block.path ~= "" then
    bytes, read_err = read_file(vim.fs.normalize(block.path), maximum)
    if not bytes then
      return nil, nil, mime, read_err
    end
  else
    local encoded = M.base64_data(block)
    if not encoded then
      return nil, nil, mime, "image data is missing"
    end
    local ok
    ok, bytes = pcall(vim.base64.decode, encoded)
    if not ok or type(bytes) ~= "string" or #bytes == 0 then
      return nil, nil, mime, "image data is invalid"
    end
    if #bytes > maximum then
      return nil, nil, mime, ("image is too large (%d bytes; limit %d)"):format(#bytes, maximum)
    end
  end

  local digest = vim.fn.sha256(vim.base64.encode(bytes))
  cleanup_cache()
  local path = vim.fs.joinpath(cache_dir(), digest .. extension)
  if vim.fn.filereadable(path) == 0 then
    local written, err = write_private(path, bytes)
    if not written then
      return nil, nil, mime, err or "unable to cache image"
    end
  else
    pcall(vim.uv.fs_chmod, path, 384)
  end
  return path, bytes, mime, nil, digest
end

function M.ensure(block, state)
  if state.source or state.error then
    return state.source
  end
  local path, bytes, mime, err, digest = load(block)
  state.mime_type = mime
  if err then
    state.error = err
    return nil
  end
  local pixel_width, pixel_height, dimensions_err = M.dimensions(bytes, mime)
  local maximum_pixels = M.config().max_pixels or 40 * 1000 * 1000
  if dimensions_err then
    state.error = dimensions_err
    return nil
  elseif pixel_width * pixel_height > maximum_pixels then
    state.error = ("image dimensions exceed the %d pixel limit"):format(maximum_pixels)
    return nil
  end
  state.source = {
    path = path,
    digest = digest,
    mime_type = mime,
    pixel_width = pixel_width,
    pixel_height = pixel_height,
    description = ("[Image: %s %dx%d]"):format(mime, pixel_width, pixel_height),
  }
  return state.source
end

M.cache_dir = cache_dir
return M
