local M = {}

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

local function diagnostics(bufnr, first_line, last_line)
  local items = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    local line = diagnostic.lnum + 1
    if line >= first_line and line <= last_line then
      table.insert(
        items,
        ("L%d:%d [%s] %s"):format(
          line,
          diagnostic.col + 1,
          vim.diagnostic.severity[diagnostic.severity] or "UNKNOWN",
          diagnostic.message:gsub("\n", " ")
        )
      )
    end
  end
  return items
end

local function wrap_context(bufnr, root, first_line, last_line, text, opts)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local attributes = {
    ("path=\"%s\""):format(escape_attribute(relative_path(root, path))),
    ("lines=\"%d-%d\""):format(first_line, last_line),
    ("filetype=\"%s\""):format(escape_attribute(filetype)),
    ("modified=\"%s\""):format(tostring(vim.bo[bufnr].modified)),
  }
  local blocks = {
    "<editor_context " .. table.concat(attributes, " ") .. ">",
    text,
    "</editor_context>",
  }

  if opts.include_diagnostics then
    local found = diagnostics(bufnr, first_line, last_line)
    if #found > 0 then
      vim.list_extend(blocks, { "<diagnostics>", table.concat(found, "\n"), "</diagnostics>" })
    end
  end
  return table.concat(blocks, "\n")
end

function M.range(bufnr, root, first_line, last_line, opts)
  opts = opts or {}
  local maximum = opts.max_bytes or opts.max_chars
  local text
  local truncated = false
  if maximum then
    maximum = math.max(0, math.floor(tonumber(maximum) or 0))
    text, truncated = bounded_buffer_text(bufnr, first_line, last_line, maximum)
  else
    local lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)
    text = table.concat(lines, "\n")
  end
  if truncated then
    text = text .. "\n[selection truncated by pi.nvim]"
  end
  return wrap_context(bufnr, root, first_line, last_line, text, opts)
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
