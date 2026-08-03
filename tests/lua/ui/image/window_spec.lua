local config = require("pi.config")
local image_data = require("pi.ui.image")
local ImagePreview = require("pi.ui.image.window").ImagePreview

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
local source_block = { type = "image", mimeType = "image/png", data = png_base64 }
assert(image_data.prepare(source_block, 20), "window fixture image was not prepared")

config.setup({ images = { backend = "text", max_width = 32, max_height = 16 } })
local clears = 0
local releases = 0
local group = vim.api.nvim_create_augroup("PiNvimImageWindowSpec", { clear = true })
local window

local function run()
  window = ImagePreview.new({
    root = vim.fs.joinpath(vim.fn.getcwd(), "image-window-project"),
    backend = {
      is_terminal = function()
        return false
      end,
      clear = function()
        clears = clears + 1
      end,
    },
    ui_group = group,
    border = function()
      return "single"
    end,
    track_image = function() end,
    release_image = function(block)
      releases = releases + 1
      image_data.release(block)
    end,
  })

  assert(window:open({ block = source_block }), "ImagePreview did not open from its explicit dependencies")
  assert(window:is_open() and window:owns_buffer(window.buf), "ImagePreview did not own its window and buffer")
  local first_buffer = window.buf
  window:close()
  assert(not window:is_open() and not vim.api.nvim_buf_is_valid(first_buffer), "ImagePreview close leaked its buffer")
  assert(clears >= 1 and releases == 1, "ImagePreview close did not release backend and source state")

  assert(window:open({ block = source_block }), "ImagePreview did not reopen")
  local wiped_buffer = window.buf
  vim.api.nvim_buf_delete(wiped_buffer, { force = true })
  assert(not window:is_open() and window.buf == nil, "buffer wipe left stale ImagePreview state")
  window:destroy()
  window:destroy()
end

local ok, err = xpcall(run, debug.traceback)
if window then
  pcall(window.destroy, window)
end
pcall(vim.api.nvim_del_augroup_by_id, group)
if not ok then
  error(err)
end

print("image_window_spec: ok")
