local image_data = require("pi.ui.image")

local M = {}

function M.extract_reasoning_header(text)
  text = type(text) == "string" and text or ""
  local open_start, open_end = text:find("**", 1, true)
  if not open_start then
    return nil
  end
  local close_start = text:find("**", open_end + 1, true)
  if not close_start then
    return nil
  end
  local header = vim.trim(text:sub(open_end + 1, close_start - 1)):gsub("%s+", " ")
  return header ~= "" and header or nil
end

function M.utf8_tail(text, maximum)
  if #text <= maximum then
    return text, 0
  end
  local first = #text - maximum + 1
  while first <= #text do
    local byte = text:byte(first)
    if not byte or byte < 0x80 or byte > 0xBF then
      break
    end
    first = first + 1
  end
  return text:sub(first), first - 1
end

function M.utf8_head(text, maximum)
  if #text <= maximum then
    return text, 0
  end
  local boundary = maximum
  while boundary > 0 do
    local next_byte = text:byte(boundary + 1)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    boundary = boundary - 1
  end
  return text:sub(1, boundary), #text - boundary
end

local arg_key_priority = {
  path = 1,
  file_path = 1,
  command = 2,
  pattern = 3,
  query = 3,
  glob = 3,
  offset = 4,
  limit = 4,
  edits = 10,
  oldText = 11,
  newText = 11,
  old_string = 11,
  new_string = 11,
  content = 12,
}
local arg_key_order = {
  "path",
  "file_path",
  "command",
  "pattern",
  "query",
  "glob",
  "offset",
  "limit",
  "edits",
  "oldText",
  "newText",
  "old_string",
  "new_string",
  "content",
}

local function bounded_arg_keys(value, maximum)
  local keys = {}
  local seen = {}
  local overflow = false
  for _, key in ipairs(arg_key_order) do
    seen[key] = true
    if value[key] ~= nil then
      if #keys < maximum then
        table.insert(keys, key)
      else
        overflow = true
      end
    end
  end
  for key in pairs(value) do
    if not seen[key] then
      if #keys >= maximum then
        overflow = true
        break
      end
      table.insert(keys, key)
    end
  end
  table.sort(keys, function(left, right)
    local left_priority = arg_key_priority[left] or 100
    local right_priority = arg_key_priority[right] or 100
    if left_priority == right_priority then
      if type(left) == "number" and type(right) == "number" then
        return left < right
      end
      return tostring(left) < tostring(right)
    end
    return left_priority < right_priority
  end)
  return keys, overflow
end

function M.limited_tool_args(args, maximum, maximum_nodes)
  local retained = 0
  local omitted = 0
  local nodes = 0
  maximum_nodes = maximum_nodes or 2048

  local function copy(value)
    if nodes >= maximum_nodes then
      omitted = omitted + 1
      return nil
    end
    nodes = nodes + 1
    if type(value) == "string" then
      local kept, removed = M.utf8_head(value, math.max(0, maximum - retained))
      retained = retained + #kept
      omitted = omitted + removed
      return kept
    elseif type(value) ~= "table" then
      return value
    end

    local result = {}
    local keys, overflow = bounded_arg_keys(value, math.max(0, maximum_nodes - nodes))
    if overflow then
      omitted = omitted + 1
    end
    for _, key in ipairs(keys) do
      local copied = copy(value[key])
      if copied ~= nil then
        result[key] = copied
      end
    end
    return result
  end

  return copy(type(args) == "table" and args or {}) or {}, retained, omitted
end

function M.summarized_tool_args(args)
  local summary = {}
  for _, key in ipairs({ "path", "file_path", "command", "pattern", "query", "glob", "offset", "limit" }) do
    if args[key] ~= nil then
      summary[key] = args[key]
    end
  end
  return M.limited_tool_args(summary, 512, 32)
end

function M.result_without_content(result)
  local copy = {}
  if type(result) ~= "table" then
    copy.content = {}
    return copy
  end
  for key, value in pairs(result or {}) do
    if key ~= "content" then
      copy[key] = value
    end
  end
  copy.content = {}
  return copy
end

function M.details_without_output(details)
  local copy = {}
  if type(details) ~= "table" then
    return copy
  end
  for key, value in pairs(details or {}) do
    if key ~= "output" then
      copy[key] = value
    end
  end
  return copy
end

function M.limited_result(result, maximum)
  local limited = { content = {} }
  local retained = 0
  local used = 0
  local omitted = 0
  for _, block in ipairs((type(result) == "table" and result.content) or {}) do
    local remaining = math.max(0, maximum - used)
    if block.type == "text" then
      local text = type(block.text) == "string" and block.text or ""
      local kept, removed = M.utf8_tail(text, remaining)
      omitted = omitted + removed
      if kept ~= "" then
        table.insert(limited.content, { type = "text", text = kept })
        retained = retained + #kept
        used = used + #kept
      end
    elseif block.type == "image" then
      local payload_bytes = image_data.attachment_payload_bytes(block)
      if payload_bytes <= remaining then
        local localized = image_data.localize(block)
        if localized then
          localized._pi_transcript_bytes = image_data.presentation_bytes(localized)
          table.insert(limited.content, localized)
          retained = retained + localized._pi_transcript_bytes
          used = used + payload_bytes
        end
      else
        omitted = omitted + payload_bytes
        table.insert(limited.content, {
          type = "omitted",
          reason = "image_limit",
          omittedBytes = payload_bytes,
          clientOmitted = true,
        })
      end
    end
  end
  for key, value in pairs(type(result) == "table" and result or {}) do
    if key ~= "content" then
      if type(value) == "string" then
        local kept, removed = M.utf8_head(value, math.max(0, maximum - used))
        limited[key] = kept
        retained = retained + #kept
        used = used + #kept
        omitted = omitted + removed
      elseif type(value) == "table" then
        local kept, kept_bytes, removed = M.limited_tool_args(value, math.max(0, maximum - used), 512)
        limited[key] = kept
        retained = retained + kept_bytes
        used = used + kept_bytes
        omitted = omitted + removed
      else
        limited[key] = value
      end
    end
  end
  if omitted > 0 then
    if type(limited.details) ~= "table" then
      limited.details = {}
    end
    limited.details.clientTruncated = true
    limited.details.clientOmittedBytes = (limited.details.clientOmittedBytes or 0) + omitted
    limited.details.clientRetainedBytes = retained
  end
  return limited, retained
end

function M.bounded_user(text, content, maximum, image_options)
  text = type(text) == "string" and text or ""
  local kept_text, omitted = M.utf8_head(text, maximum)
  local retained = #kept_text
  local images = {}
  local image_count = 0
  local maximum_images = (image_options or {}).attachment_max_count or 4
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "image" then
      image_count = image_count + 1
      if image_count <= maximum_images and retained < maximum then
        local localized = image_data.localize(block)
        local bytes = image_data.presentation_bytes(localized)
        if localized and retained + bytes <= maximum then
          localized._pi_transcript_bytes = bytes
          table.insert(images, localized)
          retained = retained + bytes
        elseif localized then
          image_data.release(localized)
          omitted = omitted + image_data.attachment_payload_bytes(block)
        end
      else
        omitted = omitted + image_data.attachment_payload_bytes(block)
      end
    end
  end
  return kept_text, images, retained, omitted
end

function M.bounded_assistant(message, maximum, image_options)
  message = type(message) == "table" and message or {}
  local limited = { content = {} }
  local retained = 0
  local omitted = 0
  for _, key in ipairs({ "role", "stopReason", "errorMessage" }) do
    if type(message[key]) == "string" then
      local kept, removed = M.utf8_head(message[key], math.max(0, maximum - retained))
      if kept ~= "" then
        limited[key] = kept
        retained = retained + #kept
      end
      omitted = omitted + removed
    end
  end

  local image_count = 0
  local maximum_images = (image_options or {}).attachment_max_count or 4
  local had_thinking = false
  for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
    if block.type == "text" or block.type == "thinking" then
      local field = block.type == "text" and "text" or "thinking"
      local value = type(block[field]) == "string" and block[field] or ""
      had_thinking = had_thinking or (block.type == "thinking" and value ~= "")
      local kept, removed = M.utf8_head(value, math.max(0, maximum - retained))
      if kept ~= "" then
        table.insert(limited.content, { type = block.type, [field] = kept })
        retained = retained + #kept
      end
      omitted = omitted + removed
    elseif block.type == "image" then
      image_count = image_count + 1
      if image_count <= maximum_images and retained < maximum then
        local localized = image_data.localize(block)
        local bytes = image_data.presentation_bytes(localized)
        if localized and retained + bytes <= maximum then
          localized._pi_transcript_bytes = bytes
          table.insert(limited.content, localized)
          retained = retained + bytes
        elseif localized then
          image_data.release(localized)
          omitted = omitted + image_data.attachment_payload_bytes(block)
        end
      else
        omitted = omitted + image_data.attachment_payload_bytes(block)
      end
    end
  end
  return limited, retained, omitted, had_thinking
end

return M
