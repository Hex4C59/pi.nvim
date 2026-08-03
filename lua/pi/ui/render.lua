local engine = require("pi.ui.render.engine")

local M = {}

function M.render(items, opts)
  return engine.render(items, opts)
end

function M.render_welcome(opts)
  return engine.render_welcome(opts)
end

M.split_lines = engine.split_lines
M.result_text = engine.result_text
M.format_duration = engine.format_duration
M.format_elapsed = engine.format_elapsed

return M
