local image_data = require("pi.ui.image")

local M = {}

local function item_identity(item, opts)
  return tostring(item._pi_id or item.id or (opts.item_ids and opts.item_ids[item]) or "item")
end

function M.render(canvas, block, prefix, line_highlight, item, block_index, opts)
  prefix = prefix or "   "
  line_highlight = line_highlight or "PiCanvasNormal"
  local prepared = image_data.prepared(block)
  local preview = image_data.preview(block)
  if opts.image_terminal and prepared then
    local first_row = canvas:add(prefix .. string.rep(" ", prepared.width), {
      highlight = "PiImageSurface",
      line_highlight = line_highlight,
    })
    canvas:image({
      key = table.concat({ item_identity(item, opts), tostring(block_index), prepared.key }, ":"),
      content_key = prepared.key,
      block = block,
      path = prepared.path,
      row = first_row,
      col = #prefix,
      width = prepared.width,
      height = prepared.height,
      range_height = 1,
      conceal = true,
    })
    return first_row
  elseif preview then
    local first_row
    for index, preview_row in ipairs(preview.rows) do
      local row_prefix = index == 1 and prefix or string.rep(" ", #prefix)
      local row = canvas:add(row_prefix .. preview_row.text, { line_highlight = line_highlight })
      first_row = first_row or row
      for _, mark in ipairs(preview_row.marks) do
        canvas:mark(row, #row_prefix + mark.start_col, #row_prefix + mark.end_col, mark.highlight, 150)
      end
    end
    if first_row and prepared then
      canvas:image({
        key = table.concat({ item_identity(item, opts), tostring(block_index), prepared.key, "preview" }, ":"),
        content_key = prepared.key,
        block = block,
        path = prepared.path,
        row = first_row,
        col = #prefix,
        width = prepared.width,
        height = prepared.height,
        range_height = prepared.height,
        mode = "blocks",
      })
    end
    return first_row
  else
    local row = canvas:add(prefix .. image_data.fallback(block), {
      highlight = "PiImageFallback",
      line_highlight = line_highlight,
    })
    return row
  end
end

return M
