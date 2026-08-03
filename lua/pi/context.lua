local M = {}

local selection_truncated_marker = "[selection truncated by pi.nvim]"
local context_omitted_marker = "[editor context omitted: byte budget too small]"
local default_diagnostics_max_count = 100
local default_diagnostic_max_message_bytes = 1000
local default_diagnostics_max_bytes = 20 * 1024

local function escape_attribute(value)
  return value:gsub("&", "&amp;"):gsub("\"", "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function normalize_path(path)
  return vim.fs.normalize(path)
end

function M.is_within_root(root, path)
  if not root or root == "" or not path or path == "" then
    return false
  end

  root = normalize_path(root)
  path = normalize_path(path)
  if path == root then
    return true
  end
  if not vim.startswith(path, root) then
    return false
  end
  if root:match("[/\\]$") then
    return true
  end

  local boundary = path:sub(#root + 1, #root + 1)
  return boundary == "/" or boundary == "\\"
end

function M.root(bufnr, markers)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local source = name ~= "" and name or vim.uv.cwd()
  return vim.fs.normalize(vim.fs.root(source, markers) or vim.uv.cwd())
end

local function relative_path(root, path)
  root = normalize_path(root)
  path = normalize_path(path)
  if type(vim.fs.relpath) == "function" then
    return vim.fs.relpath(root, path) or path
  end
  if not M.is_within_root(root, path) then
    return path
  end
  if root == path then
    return "."
  end

  local first = #root + 1
  while path:sub(first, first) == "/" or path:sub(first, first) == "\\" do
    first = first + 1
  end
  return path:sub(first)
end

local function truncate_utf8_bytes(text, maximum)
  maximum = math.max(0, math.floor(tonumber(maximum) or #text))
  if #text <= maximum then
    return text, false
  end

  local boundary = maximum
  while boundary > 0 do
    local next_byte = text:byte(boundary + 1)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    boundary = boundary - 1
  end
  return text:sub(1, boundary), true
end

local function buffer_line_bytes(bufnr, row, line_count)
  local first = vim.api.nvim_buf_get_offset(bufnr, row)
  local following = vim.api.nvim_buf_get_offset(bufnr, row + 1)
  local newline = row < line_count - 1 and 1 or 0
  return math.max(0, following - first - newline)
end

local function bounded_buffer_text(bufnr, first_line, last_line, maximum)
  local first_row = first_line - 1
  local last_row = last_line
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local parts = {}
  local retained = 0
  local row = first_row
  local chunk_lines = 256
  local truncated = false

  while row < last_row and retained < maximum do
    local chunk_start = row
    local chunk_end = row
    local chunk_bytes = 0
    while chunk_end < last_row and chunk_end - chunk_start < chunk_lines do
      local separator = chunk_end > first_row and 1 or 0
      local bytes = buffer_line_bytes(bufnr, chunk_end, line_count)
      if retained + chunk_bytes + separator + bytes > maximum then
        break
      end
      chunk_bytes = chunk_bytes + separator + bytes
      chunk_end = chunk_end + 1
    end

    if chunk_end > chunk_start then
      local lines = vim.api.nvim_buf_get_lines(bufnr, chunk_start, chunk_end, false)
      local text = table.concat(lines, "\n")
      if chunk_start > first_row then
        text = "\n" .. text
      end
      parts[#parts + 1] = text
      retained = retained + #text
      row = chunk_end
    else
      local available = maximum - retained
      if row > first_row and available > 0 then
        parts[#parts + 1] = "\n"
        retained = retained + 1
        available = available - 1
      end
      if available > 0 then
        local bytes = buffer_line_bytes(bufnr, row, line_count)
        local take = math.min(bytes, available + 4)
        local text = table.concat(vim.api.nvim_buf_get_text(bufnr, row, 0, row, take, {}), "\n")
        text = truncate_utf8_bytes(text, available)
        parts[#parts + 1] = text
        retained = retained + #text
      end
      truncated = true
      row = last_row
    end
  end

  return table.concat(parts), truncated or row < last_row
end

local function normalized_limit(value, fallback)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    value = fallback
  end
  return math.max(0, math.floor(value))
end

local function context_header(bufnr, root, first_line, last_line)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local attributes = {
    ("path=\"%s\""):format(escape_attribute(relative_path(root, path))),
    ("lines=\"%d-%d\""):format(first_line, last_line),
    ("filetype=\"%s\""):format(escape_attribute(filetype)),
    ("modified=\"%s\""):format(tostring(vim.bo[bufnr].modified)),
  }
  return "<editor_context " .. table.concat(attributes, " ") .. ">"
end

local function diagnostic_position(diagnostic)
  local first = math.max(0, math.floor(tonumber(diagnostic.lnum) or 0))
  local last = math.max(first, math.floor(tonumber(diagnostic.end_lnum) or first))
  return first, last
end

local function diagnostic_severity(diagnostic)
  local severity = math.floor(tonumber(diagnostic.severity) or 0)
  if severity >= vim.diagnostic.severity.ERROR and severity <= vim.diagnostic.severity.HINT then
    return severity
  end
  return vim.diagnostic.severity.HINT + 1
end

local function collect_diagnostics(bufnr, first_line, last_line, opts)
  local matching = {}
  local first_row = first_line - 1
  local last_row = last_line - 1
  for index, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if type(diagnostic) == "table" then
      local diagnostic_first, diagnostic_last = diagnostic_position(diagnostic)
      if diagnostic_first <= last_row and diagnostic_last >= first_row then
        matching[#matching + 1] = {
          diagnostic = diagnostic,
          first = diagnostic_first,
          last = diagnostic_last,
          severity = diagnostic_severity(diagnostic),
          index = index,
        }
      end
    end
  end

  table.sort(matching, function(left, right)
    if left.severity ~= right.severity then
      return left.severity < right.severity
    end
    if left.first ~= right.first then
      return left.first < right.first
    end
    local left_col = math.max(0, math.floor(tonumber(left.diagnostic.col) or 0))
    local right_col = math.max(0, math.floor(tonumber(right.diagnostic.col) or 0))
    if left_col ~= right_col then
      return left_col < right_col
    end
    if left.last ~= right.last then
      return left.last < right.last
    end
    local left_end_col = math.max(left_col, math.floor(tonumber(left.diagnostic.end_col) or left_col))
    local right_end_col = math.max(right_col, math.floor(tonumber(right.diagnostic.end_col) or right_col))
    if left_end_col ~= right_end_col then
      return left_end_col < right_end_col
    end
    return left.index < right.index
  end)

  local maximum_count = normalized_limit(opts.diagnostics_max_count, default_diagnostics_max_count)
  local message_maximum = normalized_limit(opts.diagnostic_max_message_bytes, default_diagnostic_max_message_bytes)
  local records = {}
  for index = 1, math.min(#matching, maximum_count) do
    local item = matching[index]
    local diagnostic = item.diagnostic
    local message, truncated = truncate_utf8_bytes(
      type(diagnostic.message) == "string" and diagnostic.message or tostring(diagnostic.message or ""),
      message_maximum
    )
    message = message:gsub("[\r\n]+", " ")
    local column = math.max(0, math.floor(tonumber(diagnostic.col) or 0)) + 1
    records[#records + 1] = {
      text = ("L%d:%d [%s] %s"):format(
        item.first + 1,
        column,
        vim.diagnostic.severity[item.severity] or "UNKNOWN",
        message
      ),
      message_truncated = truncated,
    }
  end

  return {
    total = #matching,
    records = records,
  }
end

local function serialize_diagnostics(data, maximum)
  if not data or data.total == 0 or maximum <= 0 then
    return nil
  end

  local function serialize(included, messages_truncated)
    local blocks = {
      ("<diagnostics total=\"%d\" included=\"%d\" omitted=\"%d\" messages_truncated=\"%d\">"):format(
        data.total,
        included,
        data.total - included,
        messages_truncated
      ),
    }
    for index = 1, included do
      blocks[#blocks + 1] = data.records[index].text
    end
    blocks[#blocks + 1] = "</diagnostics>"
    return table.concat(blocks, "\n")
  end

  local included = 0
  local messages_truncated = 0
  local section = serialize(0, 0)
  if #section > maximum then
    return nil
  end

  for index, record in ipairs(data.records) do
    local candidate_truncated = messages_truncated + (record.message_truncated and 1 or 0)
    local candidate = serialize(index, candidate_truncated)
    if #candidate > maximum then
      break
    end
    included = index
    messages_truncated = candidate_truncated
    section = candidate
  end

  return section
end

local function bounded_selection(bufnr, first_line, last_line, maximum)
  local text, truncated = bounded_buffer_text(bufnr, first_line, last_line, maximum)
  if not truncated then
    return text
  end

  local separator_bytes = maximum > #selection_truncated_marker and 1 or 0
  local text_maximum = math.max(0, maximum - #selection_truncated_marker - separator_bytes)
  text = bounded_buffer_text(bufnr, first_line, last_line, text_maximum)
  if #selection_truncated_marker > maximum then
    return truncate_utf8_bytes(selection_truncated_marker, maximum)
  end
  if text ~= "" then
    return text .. "\n" .. selection_truncated_marker
  end
  return selection_truncated_marker
end

local function bounded_omission(maximum)
  local marker = truncate_utf8_bytes(context_omitted_marker, maximum)
  return marker
end

local function wrap_context(bufnr, root, first_line, last_line, opts, maximum)
  local header = context_header(bufnr, root, first_line, last_line)
  local closing = "</editor_context>"
  local base_bytes = #header + #closing + 2
  if maximum and base_bytes > maximum then
    return bounded_omission(maximum)
  end

  local diagnostic_data
  if opts.include_diagnostics then
    diagnostic_data = collect_diagnostics(bufnr, first_line, last_line, opts)
  end

  local diagnostics_maximum = normalized_limit(opts.diagnostics_max_bytes, default_diagnostics_max_bytes)
  if maximum then
    diagnostics_maximum = math.min(diagnostics_maximum, math.floor((maximum - base_bytes) / 4))
  end
  local diagnostic_section = serialize_diagnostics(diagnostic_data, diagnostics_maximum - 1)
  local diagnostic_suffix = diagnostic_section and ("\n" .. diagnostic_section) or ""

  local text
  if maximum then
    local text_maximum = maximum - base_bytes - #diagnostic_suffix
    text = bounded_selection(bufnr, first_line, last_line, text_maximum)
  else
    local lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)
    text = table.concat(lines, "\n")
  end

  local wrapped = header .. "\n" .. text .. "\n" .. closing .. diagnostic_suffix
  if maximum and #wrapped > maximum then
    return bounded_omission(maximum)
  end
  return wrapped
end

function M.range(bufnr, root, first_line, last_line, opts)
  opts = opts or {}
  local maximum = opts.max_bytes or opts.max_chars
  if maximum then
    maximum = normalized_limit(maximum, 0)
  end
  return wrap_context(bufnr, root, first_line, last_line, opts, maximum)
end

function M.buffer(bufnr, root, opts)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  return M.range(bufnr, root, 1, last_line, opts)
end

function M.refresh_unmodified(root)
  root = normalize_path(root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and name ~= ""
      and M.is_within_root(root, name)
      and not vim.bo[bufnr].modified
    then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! checktime")
      end)
    end
  end
end

return M
