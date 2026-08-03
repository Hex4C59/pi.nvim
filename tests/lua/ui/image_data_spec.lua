local config = require("pi.config")
local renderer = require("pi.ui.render")
local image_data = require("pi.ui.image")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local function image_block(data)
  return {
    type = "image",
    mimeType = "image/png",
    data = data or png_base64,
  }
end

config.setup({
  images = {
    backend = "text",
    max_bytes = 2 * 1024 * 1024,
    max_width = 32,
    max_height = 16,
  },
})

local image = image_block()
local prepared = assert(image_data.prepare(image, 32), "valid PNG was not prepared")
assert(prepared.pixel_width == 1 and prepared.pixel_height == 1, "PNG dimensions were not read")
assert(prepared.width == 32 and prepared.height == 16, "terminal cell dimensions were not bounded")
assert(vim.fn.filereadable(prepared.path) == 1, "prepared image was not cached")
local stat = assert(vim.uv.fs_stat(prepared.path), "cached image is missing")
assert(bit.band(stat.mode, 511) == 384, "cached image permissions must be 0600")
local cache_stat = assert(vim.uv.fs_stat(vim.fs.dirname(prepared.path)), "image cache directory is missing")
assert(bit.band(cache_stat.mode, 511) == 448, "image cache directory permissions must be 0700")
assert(image_data.fallback(image):find("1x1", 1, true), "text fallback omitted image dimensions")

local user = { type = "user", _pi_id = "user:1", text = "", content = { image } }
local assistant = {
  type = "assistant",
  _pi_id = "assistant:2",
  message = { content = { image } },
}
local tool = {
  type = "tool",
  _pi_id = "tool:3",
  id = "tool-call",
  name = "read",
  state = "done",
  expanded = true,
  result = { content = { image } },
}
local lines, _, _, _, placements = renderer.render({ user, assistant, tool }, {
  width = 40,
  image_terminal = true,
  tools_expanded = true,
})
assert(#placements == 3, "user, assistant, and tool images must all produce placements")
assert(#lines < prepared.height * 3, "terminal image anchors duplicated the provider's visual rows")
assert(placements[1].row >= 0 and placements[1].col > 0, "placement coordinates are invalid")
assert(placements[1].path == prepared.path, "placement did not use the prepared cache file")
assert(placements[1].key ~= placements[2].key, "repeated image instances must have distinct keys")
assert(placements[2].key ~= placements[3].key, "tool image instance key collided")
for _, placement in ipairs(placements) do
  assert(placement.range_height == 1 and placement.conceal, "terminal image did not use one concealed anchor row")
end

local text_lines, _, _, _, text_placements = renderer.render({ user }, {
  width = 40,
  image_terminal = false,
})
assert(#text_placements == 0, "text backend emitted a terminal placement")
assert(table.concat(text_lines, "\n"):find("[Image: image/png 1x1]", 1, true), "text fallback was not rendered")

local original_set_hl = vim.api.nvim_set_hl
vim.api.nvim_set_hl = function(namespace, name, value)
  if name:find("^PiImagePixel_") then
    error("simulated highlight exhaustion")
  end
  return original_set_hl(namespace, name, value)
end
local failed_preview, highlight_err = image_data._preview_from_rgba(string.rep(string.char(17, 34, 51, 255), 2), 1, 1)
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
local block_preview = assert(image_data._preview_from_rgba(rgba, 2, 1))
local preview_image = image_block()
local preview_prepared = assert(image_data.prepare(preview_image, 2))
preview_prepared.preview = block_preview
local preview_lines, preview_marks, _, _, preview_placements = renderer.render({
  { type = "assistant", _pi_id = "assistant:block-preview", message = { content = { preview_image } } },
}, {
  width = 20,
  image_terminal = false,
})
assert(
  #preview_placements == 1 and preview_placements[1].mode == "blocks",
  "colored block preview did not expose a clickable image range"
)
assert(table.concat(preview_lines, "\n"):find("▀▀", 1, true), "colored block fallback did not render image cells")
local pixel_marks = 0
for _, mark in ipairs(preview_marks) do
  if mark.highlight and mark.highlight:find("^PiImagePixel_") then
    pixel_marks = pixel_marks + 1
  end
end
assert(pixel_marks == 2, "colored block fallback did not preserve per-cell image colors")

local function high_color_rgba(seed)
  local pixels = {}
  for index = 1, 72 * 64 do
    pixels[index] =
      string.char((index * 37 + seed * 17) % 256, (index * 73 + seed * 29) % 256, (index * 109 + seed * 43) % 256, 255)
  end
  return table.concat(pixels)
end

for seed = 1, 8 do
  assert(image_data._preview_from_rgba(high_color_rgba(seed), 72, 32), "high-color preview failed")
end
assert(
  image_data._preview_highlight_count() <= image_data._preview_highlight_limit,
  "colored previews exceeded the fixed highlight palette"
)
local refreshed, refresh_err = image_data.refresh_preview_highlights()
assert(refreshed, "ColorScheme refresh failed after high-color previews: " .. tostring(refresh_err))

print("image_data_spec: ok")
