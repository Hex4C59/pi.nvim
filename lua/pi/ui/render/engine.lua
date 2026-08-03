-- Private rendering engine. Public callers use pi.ui.render.
local M = {}
local Canvas = require("pi.ui.render.canvas").Canvas
local messages = require("pi.ui.render.messages")
local process = require("pi.ui.render.process")
local text = require("pi.ui.render.text")
local welcome = require("pi.ui.render.welcome")
local split_lines = text.split_lines
local result_text = text.result_text
local format_duration = text.format_duration
local format_elapsed = text.format_elapsed

function M.render_welcome(opts)
  return welcome.render(opts)
end

function M.render(items, opts)
  opts = opts or {}
  opts = vim.tbl_extend("force", {}, opts)
  opts.item_ids = {}
  for index, item in ipairs(items) do
    opts.item_ids[item] = index
  end
  local canvas = Canvas.new()
  local tool_ranges = {}
  local process_ranges = {}
  if opts.welcome then
    welcome.render_into(canvas, vim.tbl_extend("force", { width = opts.width }, opts.welcome))
  end

  if not opts.collapse_processes then
    process.render_range(canvas, items, 1, #items, opts, tool_ranges)
    return canvas.lines, canvas.marks, tool_ranges, process_ranges, canvas.images
  end

  local index = 1
  while index <= #items do
    local item = items[index]
    if item.type == "user" then
      messages.render_user(canvas, item, opts)
      local turn_first = index + 1
      local next_turn = turn_first
      while next_turn <= #items and items[next_turn].type ~= "user" do
        next_turn = next_turn + 1
      end
      local turn_last = next_turn - 1
      local active = opts.process_active == true and next_turn > #items

      if turn_first <= turn_last then
        if opts.process_expanded == true then
          local detail_opts = vim.tbl_extend("force", {}, opts, {
            hide_thinking = false,
            tools_expanded = true,
          })
          process.render_range(canvas, items, turn_first, turn_last, detail_opts, tool_ranges)
        else
          process.render_segments(canvas, items, turn_first, turn_last, opts, active, tool_ranges, process_ranges)
        end
      end
      index = next_turn
    else
      local range_last = index
      while range_last + 1 <= #items and items[range_last + 1].type ~= "user" do
        range_last = range_last + 1
      end
      process.render_range(canvas, items, index, range_last, opts, tool_ranges)
      index = range_last + 1
    end
  end

  return canvas.lines, canvas.marks, tool_ranges, process_ranges, canvas.images
end

M.split_lines = split_lines
M.result_text = result_text
M.format_duration = format_duration
M.format_elapsed = format_elapsed
return M
