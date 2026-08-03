local M = {}
local highlights = {}
local palette_levels = { 0x00, 0x80, 0xFF }
local palette_size = (#palette_levels) ^ 3
local highlight_limit = palette_size ^ 2

local function color_hex(value)
  return ("#%06x"):format(value)
end

local function quantize_color(value)
  local function channel_index(channel)
    return math.min(#palette_levels - 1, math.floor(channel * (#palette_levels - 1) / 255 + 0.5))
  end

  local red = math.floor(value / 65536) % 256
  local green = math.floor(value / 256) % 256
  local blue = value % 256
  local red_index = channel_index(red)
  local green_index = channel_index(green)
  local blue_index = channel_index(blue)
  local index = red_index * 9 + green_index * 3 + blue_index
  local quantized = palette_levels[red_index + 1] * 65536
    + palette_levels[green_index + 1] * 256
    + palette_levels[blue_index + 1]
  return index, quantized
end

local function highlight(foreground, background)
  local foreground_index, quantized_foreground = quantize_color(foreground)
  local background_index, quantized_background = quantize_color(background)
  local name = ("PiImagePixel_%02x_%02x"):format(foreground_index, background_index)
  if not highlights[name] then
    local value = {
      fg = color_hex(quantized_foreground),
      bg = color_hex(quantized_background),
      nocombine = true,
    }
    local ok, err = pcall(vim.api.nvim_set_hl, 0, name, value)
    if not ok then
      return nil, "unable to create colored preview highlight: " .. tostring(err)
    end
    highlights[name] = value
  end
  return name
end

local function canvas_background()
  for _, name in ipairs({ "PiCanvasNormal", "Normal" }) do
    local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(value) == "table" and value.bg then
      return value.bg
    end
  end
  return 0
end

local function composite(red, green, blue, alpha, background)
  if alpha >= 255 then
    return red * 65536 + green * 256 + blue
  end
  local bg_red = math.floor(background / 65536) % 256
  local bg_green = math.floor(background / 256) % 256
  local bg_blue = background % 256
  local inverse = 255 - alpha
  red = math.floor((red * alpha + bg_red * inverse) / 255 + 0.5)
  green = math.floor((green * alpha + bg_green * inverse) / 255 + 0.5)
  blue = math.floor((blue * alpha + bg_blue * inverse) / 255 + 0.5)
  return red * 65536 + green * 256 + blue
end

function M.from_rgba(data, width, height)
  local pixel_rows = height * 2
  local expected = width * pixel_rows * 4
  if type(data) ~= "string" or #data ~= expected then
    return nil,
      ("preview converter returned %d bytes; expected %d"):format(type(data) == "string" and #data or 0, expected)
  end
  local background = canvas_background()
  local rows = {}
  local glyph = "▀"
  for row = 0, height - 1 do
    local text = {}
    local marks = {}
    for col = 0, width - 1 do
      local top = (row * 2 * width + col) * 4 + 1
      local bottom = ((row * 2 + 1) * width + col) * 4 + 1
      local tr, tg, tb, ta = data:byte(top, top + 3)
      local br, bg, bb, ba = data:byte(bottom, bottom + 3)
      local foreground = composite(tr, tg, tb, ta, background)
      local cell_background = composite(br, bg, bb, ba, background)
      local group, highlight_err = highlight(foreground, cell_background)
      if not group then
        return nil, highlight_err
      end
      table.insert(text, glyph)
      table.insert(marks, {
        start_col = col * #glyph,
        end_col = (col + 1) * #glyph,
        highlight = group,
      })
    end
    table.insert(rows, { text = table.concat(text), marks = marks })
  end
  return { width = width, height = height, rows = rows }
end

function M.refresh_highlights()
  local first_error
  for name, value in pairs(highlights) do
    local ok, err = pcall(vim.api.nvim_set_hl, 0, name, value)
    if not ok and not first_error then
      first_error = tostring(err)
    end
  end
  return first_error == nil, first_error
end

function M.highlight_count()
  return vim.tbl_count(highlights)
end

M.highlight_limit = highlight_limit
return M
