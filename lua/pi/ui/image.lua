local source = require("pi.ui.image.source")
local preview = require("pi.ui.image.preview")
local scheduler = require("pi.ui.image.scheduler")

local M = {}

local function cancel_preview(state)
  if not state or not state.preview_task then
    return false
  end
  local task = state.preview_task
  state.preview_task = nil
  state.preview_loading = false
  return scheduler.cancel(task)
end

function M.prepare(block, available_width, callback, limits)
  if type(block) ~= "table" or block.type ~= "image" then
    return nil
  end
  local requested_width = math.max(1, math.floor(available_width or source.config().max_width or 72))
  local state = block._pi_image
  if not state then
    state = { token = 0, mime_type = source.mime_type(block) }
    block._pi_image = state
  end
  local prepared_source = source.ensure(block, state)
  if not prepared_source then
    if callback then
      callback(block, nil, state.error)
    end
    return nil
  end
  local width, height =
    source.target_size(prepared_source.pixel_width, prepared_source.pixel_height, requested_width, limits)
  local key = ("%s:%dx%d"):format(prepared_source.digest, width, height)
  if state.prepared and state.prepared.key == key then
    return state.prepared
  end

  cancel_preview(state)
  state.token = state.token + 1
  state.requested_width = requested_width
  state.preview_error = nil
  state.backend_error = nil
  state.prepared = {
    key = key,
    path = prepared_source.path,
    mime_type = prepared_source.mime_type,
    width = width,
    height = height,
    pixel_width = prepared_source.pixel_width,
    pixel_height = prepared_source.pixel_height,
    description = prepared_source.description,
  }
  if callback then
    callback(block, state.prepared, nil)
  end
  return state.prepared
end

function M.localize(block)
  if type(block) ~= "table" or block.type ~= "image" then
    return nil
  end
  if type(block.path) == "string" and block.path ~= "" and not source.base64_data(block) and block._pi_image then
    return {
      type = "image",
      mimeType = block.mimeType or block.mime_type,
      path = block.path,
      alt = type(block.alt) == "string" and block.alt or nil,
      _pi_image = block._pi_image,
    }
  end
  local nested_source = type(block.source) == "table"
      and {
        data = block.source.data,
        mimeType = block.source.mimeType,
        media_type = block.source.media_type,
        mediaType = block.source.mediaType,
      }
    or nil
  local working = {
    type = "image",
    mimeType = block.mimeType,
    mime_type = block.mime_type,
    data = block.data,
    source = nested_source,
    path = block.path,
  }
  local prepared = M.prepare(working, source.config().max_width or 72)
  local state = working._pi_image
  return {
    type = "image",
    mimeType = state and state.mime_type or source.mime_type(block),
    path = prepared and prepared.path or nil,
    alt = type(block.alt) == "string" and block.alt or nil,
    _pi_image = state,
  }
end

function M.attachment_payload_bytes(block)
  local payload = source.base64_data(block)
  return type(payload) == "string" and #payload or 0
end

function M.presentation_bytes(block)
  if type(block) ~= "table" then
    return 0
  end
  local total = 0
  for _, key in ipairs({ "mimeType", "mime_type", "path", "alt" }) do
    if type(block[key]) == "string" then
      total = total + #block[key]
    end
  end
  local state = block._pi_image
  if type(state) == "table" then
    for _, key in ipairs({ "mime_type", "error", "backend_error", "preview_error" }) do
      if type(state[key]) == "string" then
        total = total + #state[key]
      end
    end
    for _, record in ipairs({ state.source, state.prepared }) do
      if type(record) == "table" then
        for _, key in ipairs({ "path", "digest", "mime_type", "description", "key" }) do
          if type(record[key]) == "string" then
            total = total + #record[key]
          end
        end
      end
    end
    local rendered = state.prepared and state.prepared.preview or nil
    for _, row in ipairs((rendered and rendered.rows) or {}) do
      total = total + #(row.text or "")
      for _, mark in ipairs(row.marks or {}) do
        total = total + #(mark.highlight or "")
      end
    end
  end
  return total
end

function M.prepare_preview(block, callback)
  local state = type(block) == "table" and block._pi_image or nil
  local prepared = state and state.prepared or nil
  if not prepared or state.error then
    return nil
  end
  if prepared.preview then
    return prepared.preview
  end
  if state.preview_error or state.preview_loading then
    return nil
  end
  if vim.fn.executable("magick") ~= 1 then
    state.preview_error = "ImageMagick is unavailable for colored terminal preview"
    return nil
  end

  state.preview_loading = true
  state.preview_error = nil
  local token = state.token
  local task = scheduler.schedule(prepared, function(result, completed_task)
    if state.preview_task ~= completed_task or state.token ~= token then
      return
    end
    state.preview_task = nil
    state.preview_loading = false
    if result.timed_out then
      state.preview_error = ("ImageMagick preview timed out after %d ms"):format(completed_task.timeout_ms)
    elseif result.code ~= 0 then
      local reason = vim.trim(result.stderr or "")
      state.preview_error = reason ~= "" and reason or ("ImageMagick exited with code %d"):format(result.code)
    else
      local rendered, err = preview.from_rgba(result.stdout, prepared.width, prepared.height)
      prepared.preview = rendered
      state.preview_error = err
    end
    if callback then
      pcall(callback, block, prepared.preview, state.preview_error)
    end
  end)
  state.preview_task = task
  return nil
end

function M.cancel(block)
  local state = type(block) == "table" and block._pi_image or nil
  return cancel_preview(state)
end

function M.release(block)
  if type(block) ~= "table" then
    return false
  end
  local had_state = block._pi_image ~= nil
  M.cancel(block)
  block._pi_image = nil
  return had_state
end

function M.prepared(block)
  local state = type(block) == "table" and block._pi_image or nil
  if not state or state.error or state.backend_error then
    return nil
  end
  return state.prepared
end

function M.preview(block)
  local state = type(block) == "table" and block._pi_image or nil
  return state and state.prepared and state.prepared.preview or nil
end

function M.fail_backend(block, reason)
  if type(block) == "table" and type(block._pi_image) == "table" then
    block._pi_image.backend_error = tostring(reason or "terminal image placement failed")
  end
end

function M.clear_backend_error(block)
  if type(block) == "table" and type(block._pi_image) == "table" then
    block._pi_image.backend_error = nil
  end
end

function M.fallback(block)
  local state = type(block) == "table" and block._pi_image or nil
  local mime = state and state.mime_type or source.mime_type(block)
  local reason = state and (state.backend_error or state.error or state.preview_error)
  if reason and reason ~= "" then
    reason = vim.trim(tostring(reason)):gsub("%s+", " ")
    return ("[Image: %s; %s]"):format(mime, reason)
  end
  if state and state.preview_loading and state.prepared then
    local loading = state.prepared.description:gsub("%]$", "; rendering colored preview...]")
    return loading
  end
  if state and state.prepared then
    return state.prepared.description
  end
  return ("[Image: %s]"):format(mime)
end

function M.refresh_preview_highlights()
  return preview.refresh_highlights()
end

M.mime_type = source.mime_type
M._dimensions = source.dimensions
M._preview_from_rgba = preview.from_rgba
M._preview_highlight_count = preview.highlight_count
M._preview_highlight_limit = preview.highlight_limit
M._preview_work_counts = scheduler.work_counts

return M
