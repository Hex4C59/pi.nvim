local messages = require("pi.ui.render.messages")
local text = require("pi.ui.render.text")
local tools = require("pi.ui.render.tools")
local format_duration = text.format_duration
local truncate_display = text.truncate_display

local M = {}

local process_action_order = { "bash", "read", "list", "search", "edit", "other", "failed" }

local process_action_labels = {
  bash = { verb = "ran", singular = "command", plural = "commands" },
  read = { verb = "read", singular = "file", plural = "files" },
  list = { verb = "listed", singular = "directory", plural = "directories" },
  search = { verb = "searched", singular = "query", plural = "queries" },
  edit = { verb = "edited", singular = "file", plural = "files" },
  other = { verb = "used", singular = "tool", plural = "tools" },
  failed = { verb = nil, singular = "failure", plural = "failures" },
}

local function assistant_has_thinking(item)
  if item.had_thinking then
    return true
  end
  for _, block in ipairs((item.message or {}).content or {}) do
    if block.type == "thinking" and vim.trim(block.thinking or "") ~= "" then
      return true
    end
  end
  return false
end

local function public_assistant(item)
  if item.body_released then
    return item
  end
  local message = item.message or {}
  local content = {}
  for _, block in ipairs(message.content or {}) do
    if (block.type == "text" and vim.trim(block.text or "") ~= "") or block.type == "image" then
      table.insert(content, block)
    end
  end

  if #content == 0 and not message.stopReason then
    return nil
  end

  local public_message = vim.tbl_extend("force", {}, message)
  public_message.content = content
  local public_item = vim.tbl_extend("force", {}, item)
  public_item.message = public_message
  return public_item
end

local function process_action_key(item)
  if item.name == "bash" then
    return "bash"
  elseif item.name == "read" then
    return "read"
  elseif item.name == "ls" then
    return "list"
  elseif item.name == "grep" or item.name == "find" then
    return "search"
  elseif item.name == "edit" or item.name == "write" then
    return "edit"
  end
  return "other"
end

local function compact_duration(milliseconds)
  local duration = format_duration(milliseconds)
  return duration and duration:gsub("%.0s$", "s") or nil
end

local function process_summary(items, first, last)
  local has_thinking = false
  local has_process = false
  local duration_ms = 0
  local duration_known = false
  local counts = {}

  for index = first, last do
    local item = items[index]
    if item.type == "assistant" then
      local thinking = assistant_has_thinking(item)
      has_thinking = has_thinking or thinking
      has_process = has_process or thinking
      if item.duration_ms then
        duration_ms = duration_ms + item.duration_ms
        duration_known = true
      end
    elseif item.type == "tool" then
      has_process = true
      local key = process_action_key(item)
      counts[key] = (counts[key] or 0) + 1
      if item.error then
        counts.failed = (counts.failed or 0) + 1
      end
      if item.duration_ms then
        duration_ms = duration_ms + item.duration_ms
        duration_known = true
      end
    end
  end

  if not has_process then
    return nil
  end

  local label = has_thinking and "Thought" or "Worked"
  local duration = duration_known and compact_duration(duration_ms) or nil
  local parts = { duration and (label .. " for " .. duration) or label }
  for _, key in ipairs(process_action_order) do
    local count = counts[key] or 0
    if count > 0 then
      local spec = process_action_labels[key]
      local noun = count == 1 and spec.singular or spec.plural
      if spec.verb then
        table.insert(parts, ("%s %d %s"):format(spec.verb, count, noun))
      else
        table.insert(parts, ("%d %s"):format(count, noun))
      end
    end
  end
  return table.concat(parts, ", ")
end

local function render_process_summary(canvas, summary, width)
  canvas:space()
  local prefix = "   ▸ "
  local hint = " · Ctrl-O"
  local available = math.max(1, (width or 80) - 1)
  local summary_line = prefix .. summary
  local line = vim.api.nvim_strwidth(summary_line .. hint) <= available and (summary_line .. hint)
    or truncate_display(summary_line, available)
  local row = canvas:add(line, { highlight = "PiProcessSummary" })
  local marker_start = #"   "
  local marker_end = math.min(#prefix, #line)
  if marker_end > marker_start then
    canvas:mark(row, marker_start, marker_end, "PiProcessToggle", 140)
  end
  if line:sub(-#hint) == hint then
    canvas:mark(row, #line - #hint, #line, "PiHeaderHint", 140)
  end
  return row + 1
end

function M.render_range(canvas, items, first, last, opts, tool_ranges)
  local index = first
  while index <= last do
    local item = items[index]
    if item.type == "tool" then
      local group = {}
      while index <= last and items[index].type == "tool" do
        table.insert(group, items[index])
        index = index + 1
      end
      vim.list_extend(tool_ranges, tools.render_group(canvas, group, opts))
    else
      if item.type == "user" then
        messages.render_user(canvas, item, opts)
      elseif item.type == "assistant" then
        messages.render_assistant(canvas, item, opts)
      elseif item.type == "status" then
        messages.render_status(canvas, item, opts)
      end
      index = index + 1
    end
  end
end

local function render_compact_process(canvas, items, first, last, opts, process_ranges)
  local summary = process_summary(items, first, last)
  if not summary then
    M.render_range(canvas, items, first, last, opts, {})
    return
  end

  for index = first, last do
    local item = items[index]
    if item.type == "assistant" then
      local public_item = public_assistant(item)
      if public_item then
        messages.render_assistant(canvas, public_item, opts)
      end
    elseif item.type == "status" then
      messages.render_status(canvas, item, opts)
    end
  end

  local row = render_process_summary(canvas, summary, opts.width)
  table.insert(process_ranges, { first = row, last = row })
end

local function process_segments(items, first, last)
  local segments = {}
  local segment_first = first
  for index = first + 1, last do
    if items[index].type == "assistant" then
      table.insert(segments, { first = segment_first, last = index - 1 })
      segment_first = index
    end
  end
  table.insert(segments, { first = segment_first, last = last })
  return segments
end

function M.render_segments(canvas, items, first, last, opts, active, tool_ranges, process_ranges)
  local segments = process_segments(items, first, last)
  for index, segment in ipairs(segments) do
    if active and index == #segments then
      local detail_opts = vim.tbl_extend("force", {}, opts, {
        hide_thinking = true,
        hide_thinking_meta = true,
        tools_expanded = opts.tools_expanded == true,
      })
      M.render_range(canvas, items, segment.first, segment.last, detail_opts, tool_ranges)
    else
      render_compact_process(canvas, items, segment.first, segment.last, opts, process_ranges)
    end
  end
end

return M
