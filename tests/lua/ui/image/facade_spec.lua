local config = require("pi.config")
local renderer = require("pi.ui.render")
local image_data = require("pi.ui.image")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
local blocks = {}

local function image_block(data)
  local block = {
    type = "image",
    mimeType = "image/png",
    data = data or png_base64,
  }
  table.insert(blocks, block)
  return block
end

local function run()
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
  assert(#placements == 3, "user token, assistant image, and tool image must all produce descriptors")
  assert(#lines < prepared.height * 3, "terminal image anchors duplicated the provider's visual rows")
  assert(placements[1].row >= 0 and placements[1].col > 0, "placement coordinates are invalid")
  assert(placements[1].token and placements[1].block == image, "user image did not become an attachment token")
  assert(placements[2].path == prepared.path, "assistant placement did not use the prepared cache file")
  assert(placements[1].key ~= placements[2].key, "repeated image instances must have distinct keys")
  assert(placements[2].key ~= placements[3].key, "tool image instance key collided")
  for _, placement in ipairs({ placements[2], placements[3] }) do
    assert(placement.range_height == 1 and placement.conceal, "terminal image did not use one concealed anchor row")
  end

  local text_lines, _, _, _, text_placements = renderer.render({ user }, {
    width = 40,
    image_terminal = false,
  })
  assert(#text_placements == 1 and text_placements[1].token, "text backend lost the user attachment token")
  assert(table.concat(text_lines, "\n"):find("[image 1]", 1, true), "user attachment token was not rendered")
end

local ok, err = xpcall(run, debug.traceback)
for _, block in ipairs(blocks) do
  pcall(image_data.release, block)
end
if not ok then
  error(err)
end

print("image_facade_spec: ok")
