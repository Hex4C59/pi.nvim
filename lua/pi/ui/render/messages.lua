local markdown = require("pi.ui.render.markdown")
local media = require("pi.ui.render.media")
local text = require("pi.ui.render.text")
local split_lines = text.split_lines
local format_duration = text.format_duration

local M = {}

function M.render_user(canvas, item, opts)
  canvas:space()
  if item.body_released then
    local row = canvas:add(" › Earlier user message released from local memory", {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
    canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    return
  end
  local lines = split_lines(item.text)
  local images = {}
  if type(item.content) == "table" then
    for block_index, block in ipairs(item.content) do
      if block.type == "image" then
        table.insert(images, { block = block, index = block_index })
      end
    end
  end
  local rendered = false
  for index, line in ipairs(lines) do
    local prefix = index == 1 and " › " or "   "
    local row = canvas:add(prefix .. line, {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
    if index == 1 then
      canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    end
    rendered = true
  end
  for index, entry in ipairs(images) do
    local prefix = not rendered and index == 1 and " › " or "   "
    local row = media.render(canvas, entry.block, prefix, "PiUserMessageBg", item, entry.index, opts)
    if not rendered and index == 1 and row then
      canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    end
    rendered = true
  end
  if not rendered then
    canvas:add(" › ", {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
  end
  if item.body_truncated then
    canvas:add("   Client transcript limit omitted part of this message", {
      highlight = "PiToolOmitted",
      line_highlight = "PiUserMessageBg",
    })
  end
end

local function has_visible_after(content, index)
  for next_index = index + 1, #content do
    local block = content[next_index]
    if
      (block.type == "text" and vim.trim(block.text or "") ~= "")
      or (block.type == "thinking" and vim.trim(block.thinking or "") ~= "")
      or block.type == "image"
    then
      return true
    end
  end
  return false
end

local function render_assistant_meta(canvas, has_thinking, duration_ms)
  if not has_thinking then
    return
  end

  local duration = format_duration(duration_ms)
  local text = duration and ("Thought for " .. duration) or "Thinking..."
  canvas:add("   " .. text, { highlight = "PiProcessSummary" })
end

function M.render_assistant(canvas, item, opts)
  local message = item.message or {}
  local content = message.content or {}
  if item.body_released then
    canvas:space()
    canvas:add("   Earlier assistant message released from local memory", { highlight = "PiToolOmitted" })
  end
  local visible = false
  local has_thinking = false
  for _, block in ipairs(content) do
    local thinking = block.type == "thinking" and vim.trim(block.thinking or "") ~= ""
    if thinking then
      has_thinking = true
    end
    if (block.type == "text" and vim.trim(block.text or "") ~= "") or block.type == "image" then
      visible = true
    elseif thinking and (not opts.hide_thinking or not opts.hide_thinking_meta) then
      visible = true
    end
  end
  if visible then
    canvas:space()
    if not opts.hide_thinking_meta then
      render_assistant_meta(canvas, has_thinking, item.duration_ms)
    end
  end

  for index, block in ipairs(content) do
    if block.type == "thinking" and vim.trim(block.thinking or "") ~= "" then
      if not opts.hide_thinking then
        markdown.add(canvas, block.thinking, {
          highlight = "PiThinkingText",
          prefix = "   ┊ ",
          width = opts.width,
        })
        if has_visible_after(content, index) then
          canvas:blank()
        end
      end
    elseif block.type == "text" and vim.trim(block.text or "") ~= "" then
      markdown.add(canvas, block.text, {
        prefix = "   ",
        width = opts.width,
        content_block = block,
        root = opts.root,
        item = item,
        block_index = index,
        render_opts = opts,
      })
    elseif block.type == "image" then
      media.render(canvas, block, "   ", nil, item, index, opts)
    end
  end

  if item.body_truncated and not item.body_released then
    canvas:add("   Client transcript limit omitted part of this response", { highlight = "PiToolOmitted" })
  end

  if message.stopReason == "aborted" or item.was_aborted then
    canvas:blank()
    canvas:add(" Operation aborted", { highlight = "PiToolError" })
  elseif message.stopReason == "length" or item.was_length_limited then
    canvas:blank()
    canvas:add(" Response stopped at the model output limit", { highlight = "PiToolError" })
  elseif message.stopReason == "error" or item.was_error then
    canvas:blank()
    local error_lines = split_lines(message.errorMessage or "")
    if #error_lines == 0 then
      error_lines = { "Unknown error" }
    end
    for index, line in ipairs(error_lines) do
      local prefix = index == 1 and " Error: " or string.rep(" ", #" Error: ")
      canvas:add(prefix .. line, { highlight = "PiToolError" })
    end
  end
end

function M.render_status(canvas, item, opts)
  opts = opts or {}
  canvas:space()
  markdown.add(canvas, item.body_released and "Earlier status message released from local memory" or item.text, {
    highlight = item.error and "PiToolError" or "PiPanelMuted",
    width = opts.width,
  })
end

return M
