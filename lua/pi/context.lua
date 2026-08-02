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
  local lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)
  local text = table.concat(lines, "\n")
  local maximum = opts.max_bytes or opts.max_chars
  local truncated
  if maximum then
    text, truncated = truncate_utf8_bytes(text, maximum)
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
