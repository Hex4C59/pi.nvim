local markdown = require("pi.ui.render.markdown")
local media = require("pi.ui.render.media")
local text = require("pi.ui.render.text")
local split_lines = text.split_lines
local format_duration = text.format_duration

local M = {}

local function user_content_lines(item)
  local lines = { { text = "", tokens = {} } }
  local image_count = 0
  local has_text = false
  for _, block in ipairs(item.content or {}) do
    if block.type == "image" then
      image_count = image_count + 1
    elseif block.type == "text" then
      has_text = true
    end
  end

  local image_index = 0
  local previous_was_token = false
  local function append_text(value)
    value = type(value) == "string" and value or ""
    local parts = vim.split(value:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
    for index, part in ipairs(parts) do
      local line = lines[#lines]
      if previous_was_token and part ~= "" and not part:match("^%s") then
        line.text = line.text .. " "
      end
      line.text = line.text .. part
      previous_was_token = false
      if index < #parts then
        table.insert(lines, { text = "", tokens = {} })
      end
    end
  end

  if not has_text and type(item.text) == "string" and item.text ~= "" then
    append_text(item.text)
  end

  for block_index, block in ipairs(item.content or {}) do
    if block.type == "text" then
      append_text(block.text)
    elseif block.type == "image" then
      image_index = image_index + 1
      local line = lines[#lines]
      if line.text ~= "" and not line.text:match("%s$") then
        line.text = line.text .. " "
      end
      local token = ("[image %d]"):format(image_index)
      local start_col = #line.text
      line.text = line.text .. token
      table.insert(line.tokens, {
        block = block,
        block_index = block_index,
        image_index = image_index,
        image_count = image_count,
        start_col = start_col,
        end_col = start_col + #token,
      })
      previous_was_token = true
    end
  end
  return lines
end

local function user_item_identity(item, opts)
  return tostring(item._pi_id or item.id or (opts.item_ids and opts.item_ids[item]) or "item")
end

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
  local has_images = false
  for _, block in ipairs(type(item.content) == "table" and item.content or {}) do
    has_images = has_images or block.type == "image"
  end
  local lines = has_images and user_content_lines(item) or split_lines(item.text)
  local rendered = false
  for index, line in ipairs(lines) do
    local prefix = index == 1 and " › " or "   "
    local value = type(line) == "table" and line.text or line
    local row = canvas:add(prefix .. value, {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
    if index == 1 then
      canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    end
    for _, token in ipairs(type(line) == "table" and line.tokens or {}) do
      local start_col = #prefix + token.start_col
      local end_col = #prefix + token.end_col
      canvas:mark(row, start_col, end_col, "PiUserAttachment", 150)
      canvas:image({
        key = table.concat({ user_item_identity(item, opts), tostring(token.block_index), "token" }, ":"),
        block = token.block,
        row = row,
        col = start_col,
        width = end_col - start_col,
        height = 1,
        range_height = 1,
        token = true,
        image_index = token.image_index,
        image_count = token.image_count,
      })
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
