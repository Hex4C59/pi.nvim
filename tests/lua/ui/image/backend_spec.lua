local config = require("pi.config")
local image_data = require("pi.ui.image")
local image_backend = require("pi.ui.image.backend")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local function image_block()
  return {
    type = "image",
    mimeType = "image/png",
    data = png_base64,
  }
end

local placement_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(placement_buf, 0, -1, false, { "      ", "      ", "      " })
local placement_win = vim.api.nvim_open_win(placement_buf, false, {
  relative = "editor",
  row = 0,
  col = 0,
  width = 12,
  height = 3,
  style = "minimal",
})
local descriptor = {
  key = "instance:1:digest:2x2",
  path = "/tmp/pi-nvim-image-fixture.png",
  row = 0,
  col = 3,
  width = 2,
  height = 2,
  range_height = 1,
  conceal = true,
}

local selector_changes = 0
local selector_syncs = 0
local selector_adapter = {
  probe = function(_, callback)
    callback(true)
  end,
  sync = function(_, _, _, selected, on_failure)
    selector_syncs = selector_syncs + 1
    on_failure(selected[1], "conversion failed")
    return true
  end,
  clear = function() end,
}
config.setup({ images = { backend = "terminal" } })
local selector = image_backend.new({
  adapter = selector_adapter,
  on_change = function()
    selector_changes = selector_changes + 1
  end,
})
assert(selector:is_terminal(), "available selector did not activate terminal rendering")
local failed_image = image_block()
assert(image_data.prepare(failed_image, 20), "failure test image was not prepared")
selector:sync(placement_buf, placement_win, {
  vim.tbl_extend("force", vim.deepcopy(descriptor), { block = failed_image }),
})
assert(selector_syncs == 1, "selector did not call the adapter")
assert(not image_data.prepared(failed_image), "single placement failure did not downgrade its image")
assert(image_data.fallback(failed_image):find("conversion failed", 1, true), "placement failure reason was lost")
assert(selector_changes >= 2, "backend transitions did not request a transcript redraw")

config.setup({ images = { backend = "text" } })
local previous_preload = package.preload["pi.ui.image.backends.snacks"]
local previous_loaded = package.loaded["pi.ui.image.backends.snacks"]
package.loaded["pi.ui.image.backends.snacks"] = nil
package.preload["pi.ui.image.backends.snacks"] = function()
  error("text backend loaded its provider")
end
local text_backend = image_backend.new()
assert(not text_backend:is_terminal(), "text backend became terminal")
package.preload["pi.ui.image.backends.snacks"] = previous_preload
package.loaded["pi.ui.image.backends.snacks"] = previous_loaded

vim.api.nvim_win_close(placement_win, true)
vim.api.nvim_buf_delete(placement_buf, { force = true })

print("image_backend_spec: ok")
