local Canvas = {}
Canvas.__index = Canvas

function Canvas.new()
  return setmetatable({ lines = {}, marks = {}, images = {} }, Canvas)
end

function Canvas:image(descriptor)
  table.insert(self.images, descriptor)
end

function Canvas:add(text, opts)
  opts = opts or {}
  text = text or ""
  local row = #self.lines
  table.insert(self.lines, text)
  table.insert(self.marks, {
    row = row,
    start_col = opts.start_col or 0,
    end_col = opts.end_col or #text,
    highlight = opts.highlight,
    line_highlight = opts.line_highlight,
    priority = opts.priority,
  })
  return row
end

function Canvas:mark(row, start_col, end_col, highlight, priority)
  table.insert(self.marks, {
    row = row,
    start_col = start_col,
    end_col = end_col,
    highlight = highlight,
    priority = priority,
  })
end

function Canvas:blank(opts)
  self:add("", opts)
end

function Canvas:space()
  local last_line = self.lines[#self.lines]
  if last_line and last_line:find("%S") then
    self:blank()
  end
end

return { Canvas = Canvas }
