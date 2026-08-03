local config = require("pi.config")
local image_data = require("pi.ui.image")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local function image_block(data)
  return {
    type = "image",
    mimeType = "image/png",
    data = data or png_base64,
  }
end

config.setup({ images = { backend = "text", max_bytes = 1024 } })
local oversized = image_block(vim.base64.encode(string.rep("x", 1025)))
assert(not image_data.prepare(oversized, 32), "oversized compressed image was accepted")
assert(image_data.fallback(oversized):find("too large", 1, true), "size failure was not preserved in transcript text")

config.setup({ images = { backend = "text", max_pixels = 1024 } })
local png_bytes = vim.base64.decode(png_base64)
local huge_header = png_bytes:sub(1, 16) .. string.char(0, 0, 3, 232) .. string.char(0, 0, 3, 232) .. png_bytes:sub(25)
local huge = image_block(vim.base64.encode(huge_header))
assert(not image_data.prepare(huge, 32), "image exceeding the decoded pixel budget was accepted")
assert(image_data.fallback(huge):find("pixel limit", 1, true), "pixel failure was not preserved in transcript text")

config.setup({ images = { backend = "text", max_width = 32 } })
local resized = image_block()
local wide_key = assert(image_data.prepare(resized, 32)).key
local narrow_key = assert(image_data.prepare(resized, 20)).key
assert(wide_key ~= narrow_key, "resize did not update the prepared image key")
local zoomed = image_block()
local zoomed_prepared = assert(image_data.prepare(zoomed, 80, nil, { max_width = 80, max_height = 40 }))
assert(zoomed_prepared.width == 80 and zoomed_prepared.height == 40, "zoom sizing remained capped by inline limits")

local source_path = vim.fn.tempname() .. ".png"
local source_fd = assert(vim.uv.fs_open(source_path, "w", 384))
assert(vim.uv.fs_write(source_fd, png_bytes, 0) == #png_bytes, "source reuse fixture was not written")
vim.uv.fs_close(source_fd)
local file_backed = { type = "image", mimeType = "image/png", path = source_path }
assert(image_data.prepare(file_backed, 32), "file-backed image was not prepared")
local prepared_source = file_backed._pi_image.source
assert(vim.uv.fs_unlink(source_path), "source reuse fixture was not removed")
for _, width in ipairs({ 28, 24, 20, 16 }) do
  assert(image_data.prepare(file_backed, width), "resize tried to read the removed source file")
  assert(file_backed._pi_image.source == prepared_source, "resize replaced the immutable prepared source")
end

print("image_limits_spec: ok")
