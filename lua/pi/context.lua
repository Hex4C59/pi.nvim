local M = {}

local function escape_attribute(value)
  return value:gsub("&", "&amp;"):gsub("\"", "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

function M.root(bufnr, markers)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local source = name ~= "" and name or vim.uv.cwd()
  return vim.fs.normalize(vim.fs.root(source, markers) or vim.uv.cwd())
end

local function relative_path(root, path)
  local relative = vim.fs.relpath(root, path)
  return relative or path
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
  local lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)
  local text = table.concat(lines, "\n")
  if #text > opts.max_chars then
    text = text:sub(1, opts.max_chars) .. "\n[selection truncated by pi.nvim]"
  end
  return wrap_context(bufnr, root, first_line, last_line, text, opts)
end

function M.buffer(bufnr, root, opts)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  return M.range(bufnr, root, 1, last_line, opts)
end

function M.refresh_unmodified(root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and name ~= ""
      and vim.startswith(vim.fs.normalize(name), root)
      and not vim.bo[bufnr].modified
    then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! checktime")
      end)
    end
  end
end

return M
