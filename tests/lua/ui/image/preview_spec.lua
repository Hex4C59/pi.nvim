local image_data = require("pi.ui.image")
local preview = require("pi.ui.image.preview")
local renderer = require("pi.ui.render")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local original_set_hl = vim.api.nvim_set_hl
vim.api.nvim_set_hl = function(namespace, name, value)
  if name:find("^PiImagePixel_") then
    error("simulated highlight exhaustion")
  end
  return original_set_hl(namespace, name, value)
end
local failed_preview, highlight_err = preview.from_rgba(string.rep(string.char(17, 34, 51, 255), 2), 1, 1)
vim.api.nvim_set_hl = original_set_hl
assert(not failed_preview, "highlight creation failure unexpectedly produced a preview")
assert(
  highlight_err and highlight_err:find("simulated highlight exhaustion", 1, true),
  "highlight creation failure did not produce a stable preview error"
)

local rgba = table.concat({
  string.char(255, 0, 0, 255),
  string.char(0, 255, 0, 255),
  string.char(0, 0, 255, 255),
  string.char(255, 255, 0, 255),
})
local block_preview = assert(preview.from_rgba(rgba, 2, 1))
local image = { type = "image", mimeType = "image/png", data = png_base64 }
local prepared = assert(image_data.prepare(image, 2))
prepared.preview = block_preview
local lines, marks, _, _, placements = renderer.render({
  { type = "assistant", _pi_id = "assistant:block-preview", message = { content = { image } } },
}, {
  width = 20,
  image_terminal = false,
})
assert(#placements == 1 and placements[1].mode == "blocks", "block preview lost its clickable image range")
assert(table.concat(lines, "\n"):find("▀▀", 1, true), "block preview did not render image cells")
local pixel_marks = 0
for _, mark in ipairs(marks) do
  if mark.highlight and mark.highlight:find("^PiImagePixel_") then
    pixel_marks = pixel_marks + 1
  end
end
assert(pixel_marks == 2, "block preview did not preserve per-cell colors")

local function high_color_rgba(seed)
  local pixels = {}
  for index = 1, 72 * 64 do
    pixels[index] =
      string.char((index * 37 + seed * 17) % 256, (index * 73 + seed * 29) % 256, (index * 109 + seed * 43) % 256, 255)
  end
  return table.concat(pixels)
end

for seed = 1, 8 do
  assert(preview.from_rgba(high_color_rgba(seed), 72, 32), "high-color preview failed")
end
assert(preview.highlight_count() <= preview.highlight_limit, "colored previews exceeded the fixed highlight palette")
local refreshed, refresh_err = preview.refresh_highlights()
assert(refreshed, "ColorScheme refresh failed after high-color previews: " .. tostring(refresh_err))

print("image_preview_spec: ok")
