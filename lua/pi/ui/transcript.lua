local BoundedText = require("pi.bounded_text").BoundedText
local image_data = require("pi.ui.image")
local history = require("pi.ui.transcript.history")
local projection = require("pi.ui.transcript.projection")
local retention = require("pi.ui.transcript.retention")

local bounded_assistant_message = projection.bounded_assistant
local bounded_user_projection = projection.bounded_user
local details_without_output = projection.details_without_output
local extract_reasoning_header = projection.extract_reasoning_header
local limited_result = projection.limited_result
local limited_tool_args = projection.limited_tool_args
local result_without_content = projection.result_without_content
local summarized_tool_args = projection.summarized_tool_args
local utf8_head = projection.utf8_head

local Transcript = {}
Transcript.__index = Transcript

function Transcript.new(opts)
  opts = opts or {}
  return setmetatable({
    output = assert(opts.output, "Transcript output limits are required"),
    image_options = opts.images or {},
    clock = opts.clock or function()
      return vim.uv.hrtime()
    end,
    on_change = opts.on_change or function() end,
    on_invalidate = opts.on_invalidate or function() end,
    on_input_change = opts.on_input_change or function() end,
    projection_bytes = opts.projection_bytes or function()
      return 0
    end,
    items = {},
    tools_by_id = {},
    image_blocks = {},
    next_item_id = 0,
    tool_retained_bytes = 0,
    non_tool_retained_bytes = 0,
    streaming_assistant = nil,
    history_loaded = false,
    reasoning_buffer = "",
    reasoning_header = nil,
  }, Transcript)
end

function Transcript:_changed(immediate, item)
  self.on_change(immediate, item)
end

function Transcript:_image_options()
  if type(self.image_options) == "function" then
    return self.image_options() or {}
  end
  return self.image_options
end

function Transcript:_new_item_id(kind)
  self.next_item_id = self.next_item_id + 1
  return ("%s:%d"):format(kind or "item", self.next_item_id)
end

function Transcript:_set_item_body_bytes(item, retained, omitted)
  self.non_tool_retained_bytes =
    math.max(0, self.non_tool_retained_bytes - (item.body_retained_bytes or 0) + (retained or 0))
  item.body_retained_bytes = retained or 0
  item.body_omitted_bytes = omitted or 0
  item.body_truncated = (omitted or 0) > 0
end

function Transcript:retained_transcript_bytes()
  return retention.total_bytes({
    non_tool = self.non_tool_retained_bytes,
    tool = self.tool_retained_bytes,
    projection = self.projection_bytes(),
    reasoning_buffer = self.reasoning_buffer,
    reasoning_header = self.reasoning_header,
  })
end

function Transcript:_invalidate_cached_item(item)
  self.on_invalidate(item)
end

function Transcript:_track_image(block)
  if type(block) == "table" and block.type == "image" then
    self.image_blocks[block] = true
  end
  return block
end

function Transcript:_track_content_images(content)
  for _, block in ipairs(type(content) == "table" and content or {}) do
    self:_track_image(block)
  end
end

function Transcript:release_image(block)
  if not block then
    return
  end
  self.image_blocks[block] = nil
  image_data.release(block)
end

function Transcript:_refresh_image_accounting(item, block)
  if not item or not block then
    return false
  end
  if item.body_released or (item.type == "tool" and item.output_released) then
    self.image_blocks[block] = nil
    image_data.release(block)
    return false
  end
  local previous = block._pi_transcript_bytes or 0
  local current = image_data.presentation_bytes(block)
  local delta = current - previous
  block._pi_transcript_bytes = current
  if delta ~= 0 then
    if item.type == "tool" then
      item.retained_bytes = math.max(0, (item.retained_bytes or 0) + delta)
      self.tool_retained_bytes = math.max(0, self.tool_retained_bytes + delta)
    else
      item.body_retained_bytes = math.max(0, (item.body_retained_bytes or 0) + delta)
      self.non_tool_retained_bytes = math.max(0, self.non_tool_retained_bytes + delta)
    end
    self:_enforce_transcript_budget()
  end
  return not item.body_released and not (item.type == "tool" and item.output_released)
end

function Transcript:_release_images()
  for block in pairs(self.image_blocks) do
    image_data.release(block)
  end
  self.image_blocks = {}
end

function Transcript:clear()
  self:_release_images()
  self.items = {}
  self.next_item_id = 0
  self.tools_by_id = {}
  self.tool_retained_bytes = 0
  self.non_tool_retained_bytes = 0
  self.streaming_assistant = nil
  self.reasoning_buffer = ""
  self.reasoning_header = nil
  self:_changed(true)
end

function Transcript:clear_reasoning()
  self.reasoning_buffer = ""
  self.reasoning_header = nil
end

function Transcript:add_user(text, content)
  local maximum = self.output.transcript_max_bytes
  local kept_text, images, retained, omitted = bounded_user_projection(text, content, maximum, self:_image_options())
  local item = {
    type = "user",
    _pi_id = self:_new_item_id("user"),
    text = kept_text,
    content = images,
  }
  table.insert(self.items, item)
  self:_track_content_images(item.content)
  self:_set_item_body_bytes(item, retained, omitted)
  self:_enforce_transcript_budget()
  self:_changed(true)
end

function Transcript:validate_image_attachments(images)
  if type(images) ~= "table" then
    return false, "image attachments must be a list"
  end
  local options = self:_image_options()
  if #images > (options.attachment_max_count or 4) then
    return false, ("Too many image attachments (%d; limit %d)"):format(#images, options.attachment_max_count or 4)
  end
  local total = 0
  for _, image in ipairs(images) do
    if type(image) ~= "table" or image.type ~= "image" then
      return false, "image attachment is invalid"
    end
    total = total + image_data.attachment_payload_bytes(image)
  end
  if total > (options.attachment_max_bytes or 16 * 1024 * 1024) then
    return false,
      ("Image attachments are too large (%d encoded bytes; limit %d)"):format(
        total,
        options.attachment_max_bytes or 16 * 1024 * 1024
      )
  end
  return true, nil, total
end

function Transcript:localize_images(images)
  local _, localized = bounded_user_projection("", images, self.output.transcript_max_bytes, self:_image_options())
  return localized
end

function Transcript:_set_assistant_message(item, message)
  if item.message then
    self:_release_content_images(item.message.content)
  end
  local limited, retained, omitted, had_thinking =
    bounded_assistant_message(message, self.output.transcript_max_bytes, self:_image_options())
  item.message = limited
  self:_track_content_images(limited.content)
  item.had_thinking = item.had_thinking or had_thinking
  item.body_released = false
  self:_set_item_body_bytes(item, retained, omitted)
  self:_enforce_transcript_budget()
end

function Transcript:start_assistant(message)
  self.reasoning_buffer = ""
  self.reasoning_header = nil
  local item = {
    type = "assistant",
    _pi_id = self:_new_item_id("assistant"),
    message = nil,
    started_at = self.clock(),
  }
  table.insert(self.items, item)
  self.streaming_assistant = item
  self:_set_assistant_message(item, message)
  self.on_input_change()
  self:_changed(true)
end

function Transcript:_update_reasoning_status(message_event)
  if type(message_event) ~= "table" then
    return
  end

  if message_event.type == "thinking_start" then
    self.reasoning_buffer = ""
    self.reasoning_header = nil
    self.on_input_change()
  elseif message_event.type == "thinking_delta" then
    local delta = type(message_event.delta) == "string" and message_event.delta or ""
    if delta == "\n\n" then
      self.reasoning_buffer = ""
      return
    end

    self.reasoning_buffer = utf8_head(self.reasoning_buffer .. delta, math.min(4096, self.output.transcript_max_bytes))
    local header = extract_reasoning_header(self.reasoning_buffer)
    if header and header ~= self.reasoning_header then
      self.reasoning_header = utf8_head(header, 256)
      self.reasoning_buffer = ""
      self.on_input_change()
    end
  elseif message_event.type == "text_start" or message_event.type == "text_delta" then
    if self.reasoning_header then
      self.reasoning_header = nil
      self.on_input_change()
    end
    self.reasoning_buffer = ""
  end
  self:_enforce_transcript_budget()
end

function Transcript:update_assistant(message, message_event)
  if not self.streaming_assistant then
    self:start_assistant(message)
  else
    self:_set_assistant_message(self.streaming_assistant, message)
  end
  self:_update_reasoning_status(message_event)
  self:_changed(false)
end

function Transcript:end_assistant(message)
  if not self.streaming_assistant then
    self:start_assistant(message)
  else
    self:_set_assistant_message(self.streaming_assistant, message)
  end
  if self.streaming_assistant.started_at then
    self.streaming_assistant.duration_ms =
      math.max(1, math.floor((self.clock() - self.streaming_assistant.started_at) / 1000000))
  end
  self.streaming_assistant = nil
  self.reasoning_buffer = ""
  self.reasoning_header = nil
  self.on_input_change()
  self:_changed(true)
end

function Transcript:start_tool(id, name, args)
  local item = self.tools_by_id[id]
  if item then
    self:_invalidate_cached_item(item)
    item.name = name or item.name
    item.state = "pending"
  else
    item = {
      type = "tool",
      _pi_id = self:_new_item_id("tool"),
      id = id,
      name = name or "tool",
      args = {},
      state = "pending",
      started_at = self.clock(),
    }
    self.tools_by_id[id] = item
    table.insert(self.items, item)
  end
  self:_set_tool_args(item, args or item.args)
  if item.name == "bash" then
    local output = self.output
    item.bash_buffer = BoundedText.new({
      max_bytes = output.live_max_bytes,
      max_lines = output.live_max_lines,
      max_chunks = output.max_chunks,
    })
    item.bash_dirty = false
  end
  self:_changed(true)
end

function Transcript:_set_tool_args(item, args)
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - (item.args_retained_bytes or 0))
  local limited, retained, omitted = limited_tool_args(args, self.output.tool_max_bytes)
  item.args = limited
  item.args_retained_bytes = retained
  item.args_omitted_bytes = omitted
  item.args_truncated = omitted > 0
  item.args_released = false
  self.tool_retained_bytes = self.tool_retained_bytes + retained
  self:_enforce_transcript_budget()
end

function Transcript:_release_tool_args(item)
  if not item or (item.args_retained_bytes or 0) == 0 then
    return
  end
  self:_invalidate_cached_item(item)
  local previous = item.args_retained_bytes
  local summary, retained, omitted = summarized_tool_args(item.args or {})
  if retained >= previous then
    summary = {}
    retained = 0
  end
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - previous + retained)
  item.args = summary
  item.args_retained_bytes = retained
  item.args_omitted_bytes = (item.args_omitted_bytes or 0) + omitted + math.max(0, previous - retained)
  item.args_truncated = true
  item.args_released = true
end

function Transcript:_release_tool_output(item)
  if not item or (item.retained_bytes or 0) == 0 then
    return
  end
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - item.retained_bytes)
  item.retained_bytes = 0
  self:_release_content_images(item.result and item.result.content)
  item.result = result_without_content(item.result)
  item.output_released = true
end

function Transcript:_release_content_images(content)
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "image" then
      self.image_blocks[block] = nil
      image_data.release(block)
    elseif block.type == "text" and block._pi_markdown_images then
      for _, markdown_block in ipairs((block._pi_markdown_images or {}).blocks or {}) do
        self.image_blocks[markdown_block] = nil
        image_data.release(markdown_block)
      end
      block._pi_markdown_images = nil
    end
  end
end

function Transcript:_release_non_tool_body(item)
  if not item or item.body_released then
    return false
  end
  local previous = item.body_retained_bytes or 0
  self.on_invalidate(item)
  if item.type == "user" then
    self:_release_content_images(item.content)
    item.text = ""
    item.content = {}
  elseif item.type == "assistant" then
    local message = item.message or {}
    self:_release_content_images(message.content)
    item.was_aborted = message.stopReason == "aborted"
    item.was_length_limited = message.stopReason == "length"
    item.was_error = message.stopReason == "error"
    item.message = { content = {} }
  elseif item.type == "status" then
    item.text = ""
  else
    return false
  end
  item.body_released = true
  self:_set_item_body_bytes(item, 0, (item.body_omitted_bytes or 0) + previous)
  return previous > 0
end

function Transcript:_release_tool_args_fully(item)
  local released = item and (item.args_retained_bytes or 0) or 0
  if released == 0 then
    return false
  end
  self.on_invalidate(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - released)
  item.args = {}
  item.args_retained_bytes = 0
  item.args_omitted_bytes = (item.args_omitted_bytes or 0) + released
  item.args_truncated = true
  item.args_released = true
  return true
end

function Transcript:_enforce_transcript_budget()
  local maximum = self.output.transcript_max_bytes
  if self:retained_transcript_bytes() <= maximum then
    return
  end
  self.reasoning_buffer = ""
  self.reasoning_header = nil
  self.on_invalidate()
  local function over_budget()
    return self:retained_transcript_bytes() > maximum
  end

  for _, candidate in ipairs(retention.candidates(self.items, self.streaming_assistant)) do
    if not over_budget() then
      break
    end
    local item = candidate.item
    if candidate.kind == "tool_output" and not item.output_released then
      self:_release_tool_output(item)
    elseif candidate.kind == "tool_args" and not item.args_released then
      self:_release_tool_args(item)
    elseif candidate.kind == "tool_args_full" then
      self:_release_tool_args_fully(item)
    elseif candidate.kind == "body" then
      self:_release_non_tool_body(item)
    end
  end
end

function Transcript:_set_tool_result(item, result)
  self:_invalidate_cached_item(item)
  self.tool_retained_bytes = math.max(0, self.tool_retained_bytes - (item.retained_bytes or 0))
  self:_release_content_images(item.result and item.result.content)
  local remaining = math.max(0, self.output.tool_max_bytes - (item.args_retained_bytes or 0))
  local limited, retained = limited_result(result or {}, remaining)
  item.result = limited
  self:_track_content_images(limited.content)
  item.retained_bytes = retained
  item.output_released = false
  self.tool_retained_bytes = self.tool_retained_bytes + retained
  self:_enforce_transcript_budget()
end

function Transcript:_materialize_bash(item)
  if not item.bash_buffer then
    return
  end
  local stats = item.bash_buffer:stats()
  local details = {}
  details = details_without_output(item.bash_details)
  details.clientTruncated = stats.truncated
  details.clientOmittedBytes = stats.omitted_bytes
  details.clientOmittedLines = stats.omitted_lines
  details.clientRetainedBytes = stats.retained_bytes
  self:_set_tool_result(item, {
    content = { { type = "text", text = item.bash_buffer:text() } },
    details = details,
  })
  item.bash_dirty = false
end

function Transcript:materialize_pending_bash()
  for _, item in pairs(self.tools_by_id) do
    if item.bash_dirty then
      self:_materialize_bash(item)
    end
  end
end

function Transcript:update_tool(id, result)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.state = "pending"
  self:_set_tool_result(item, result)
  self:_changed(false)
end

function Transcript:append_bash_delta(id, delta)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  if not item.bash_buffer or type(delta) ~= "string" or delta == "" then
    return
  end
  item.bash_buffer:append(delta)
  item.bash_dirty = true
  self:_changed(false)
end

function Transcript:end_bash(id, data, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  data = data or {}
  local stats = item.bash_buffer and item.bash_buffer:stats() or { retained_bytes = 0, omitted_bytes = 0 }
  if item.bash_buffer and stats.retained_bytes == 0 and stats.omitted_bytes == 0 then
    item.bash_buffer:append(type(data.output) == "string" and data.output or "")
  end
  item.bash_details = data
  item.bash_dirty = true
  self:_materialize_bash(item)
  item.bash_buffer = nil
  item.bash_details = nil
  self:end_tool(id, item.result, is_error)
end

function Transcript:end_tool(id, result, is_error)
  local item = self.tools_by_id[id]
  if not item then
    return
  end
  item.error = is_error == true
  item.state = "done"
  item.bash_buffer = nil
  item.bash_details = nil
  item.bash_dirty = false
  self:_set_tool_result(item, result)
  if item.started_at then
    item.duration_ms = math.max(1, math.floor((self.clock() - item.started_at) / 1000000))
  end
  self:_changed(true)
end

function Transcript:add_status(text, is_error)
  local kept, omitted = utf8_head(type(text) == "string" and text or "", self.output.transcript_max_bytes)
  local item = {
    type = "status",
    _pi_id = self:_new_item_id("status"),
    text = kept,
    error = is_error == true,
  }
  table.insert(self.items, item)
  self:_set_item_body_bytes(item, #kept, omitted)
  self:_enforce_transcript_budget()
  self:_changed(true)
end

function Transcript:render_history(messages)
  if self.history_loaded then
    return
  end
  self.history_loaded = true
  self:_release_images()
  self.on_invalidate()
  self.items = {}
  self.next_item_id = 0
  self.tools_by_id = {}
  self.tool_retained_bytes = 0
  self.non_tool_retained_bytes = 0
  history.replay(messages, {
    user = function(event)
      local text, images, retained, omitted =
        bounded_user_projection(event.text, event.content, self.output.transcript_max_bytes, self:_image_options())
      local item = {
        type = "user",
        _pi_id = self:_new_item_id("history-user"),
        text = text,
        content = images,
      }
      table.insert(self.items, item)
      self:_set_item_body_bytes(item, retained, omitted)
      self:_enforce_transcript_budget()
    end,
    assistant = function(event)
      local assistant_item = {
        type = "assistant",
        _pi_id = self:_new_item_id("history-assistant"),
      }
      table.insert(self.items, assistant_item)
      self:_set_assistant_message(assistant_item, event.message)
    end,
    tool_call = function(event)
      local block = event.block
      local item = {
        type = "tool",
        _pi_id = self:_new_item_id("history-tool"),
        id = block.id,
        name = block.name,
        args = {},
        state = "pending",
      }
      self.tools_by_id[block.id] = item
      table.insert(self.items, item)
      self:_set_tool_args(item, block.arguments or {})
    end,
    tool_result = function(event)
      local message = event.message
      local item = self.tools_by_id[message.toolCallId]
      if item then
        item.error = message.isError == true
        item.state = "done"
        self:_set_tool_result(item, message)
      end
    end,
    bash = function(event)
      local message = event.message
      local item = {
        type = "tool",
        _pi_id = self:_new_item_id("history-bash"),
        id = "bash-" .. tostring(message.timestamp or #self.items),
        name = "bash",
        args = {},
        error = (message.exitCode or 0) ~= 0,
        state = "done",
      }
      self.tools_by_id[item.id] = item
      table.insert(self.items, item)
      self:_set_tool_args(item, { command = message.command })
      self:_set_tool_result(item, {
        content = { { type = "text", text = message.output or "" } },
        details = details_without_output(message),
      })
    end,
  })
  self:_changed(true)
end

function Transcript:find_tool(id)
  return self.tools_by_id[id]
end

function Transcript:destroy()
  self:_release_images()
  self.items = {}
  self.tools_by_id = {}
  self.next_item_id = 0
  self.tool_retained_bytes = 0
  self.non_tool_retained_bytes = 0
  self.streaming_assistant = nil
  self.reasoning_buffer = ""
  self.reasoning_header = nil
  self.on_change = function() end
  self.on_invalidate = function() end
  self.on_input_change = function() end
end

return { Transcript = Transcript }
