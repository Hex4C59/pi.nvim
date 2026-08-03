local M = {}

local code_language_aliases = {
  ["c++"] = "cpp",
  console = "bash",
  ex = "vim",
  javascriptreact = "javascript",
  js = "javascript",
  jsx = "javascript",
  md = "markdown",
  py = "python",
  rb = "ruby",
  sh = "bash",
  shell = "bash",
  ts = "typescript",
  tsx = "tsx",
  typescriptreact = "tsx",
  viml = "vim",
  yml = "yaml",
}

local plain_code_languages = {
  plain = true,
  plaintext = true,
  text = true,
  txt = true,
}

local code_highlight_cache = {}
local code_highlight_cache_order = {}
local code_highlight_cache_limit = 32
local code_highlight_max_bytes = 64 * 1024
local code_highlight_max_captures = 12000

function M.normalize_language(info)
  local language = vim.trim(info or ""):match("^{?%.?([%w_+%-]+)")
  if not language then
    return nil
  end
  language = language:lower()
  if plain_code_languages[language] then
    return nil
  end
  language = code_language_aliases[language] or language
  if vim.treesitter.language and vim.treesitter.language.get_lang then
    language = vim.treesitter.language.get_lang(language) or language
  end
  return language
end

function M.language_for_path(path)
  if not path or path == "" then
    return nil
  end
  local filetype = nil
  if vim.filetype and vim.filetype.match then
    local ok, matched = pcall(vim.filetype.match, { filename = path })
    if ok then
      filetype = matched
    end
  end
  if not filetype or filetype == "" then
    filetype = vim.fn.fnamemodify(path, ":e")
  end
  return M.normalize_language(filetype)
end

local function cache_code_highlights(key, marks)
  if code_highlight_cache[key] == nil then
    table.insert(code_highlight_cache_order, key)
  end
  code_highlight_cache[key] = marks
  while #code_highlight_cache_order > code_highlight_cache_limit do
    code_highlight_cache[table.remove(code_highlight_cache_order, 1)] = nil
  end
end

local function treesitter_code_highlights(code, language)
  if not language or code == "" or #code > code_highlight_max_bytes then
    return {}
  end

  local key = language .. "\0" .. code
  if code_highlight_cache[key] ~= nil then
    return code_highlight_cache[key]
  end

  local marks = {}
  local parsed = false
  local ok = pcall(function()
    local parser = vim.treesitter.get_string_parser(code, language)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(language, "highlights")
    if not tree or not query then
      return
    end
    parsed = true

    for capture_id, node, metadata in query:iter_captures(tree:root(), code, 0, -1) do
      local capture = query.captures[capture_id]
      if capture and capture:sub(1, 1) ~= "_" then
        local capture_metadata = metadata and metadata[capture_id]
        local start_row, start_col, end_row, end_col
        if vim.treesitter.get_range then
          local range = vim.treesitter.get_range(node, code, capture_metadata)
          start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
        else
          start_row, start_col, end_row, end_col = node:range()
        end
        local query_priority = tonumber(metadata and (metadata.priority or (capture_metadata or {}).priority)) or 100
        table.insert(marks, {
          start_row = start_row,
          start_col = start_col,
          end_row = end_row,
          end_col = end_col,
          highlight = "@" .. capture .. "." .. language,
          priority = math.max(150, math.min(250, 160 + query_priority - 100)),
        })
        if #marks > code_highlight_max_captures then
          marks = {}
          return
        end
      end
    end
  end)

  if not ok then
    return {}
  elseif not parsed then
    return {}
  end
  cache_code_highlights(key, marks)
  return marks
end

function M.apply_highlights(canvas, block)
  local code = table.concat(block.lines, "\n")
  for _, mark in ipairs(treesitter_code_highlights(code, block.language)) do
    local final_row = math.min(mark.end_row, #block.rows - 1)
    for code_row = mark.start_row, final_row do
      local line = block.lines[code_row + 1] or ""
      local start_col = code_row == mark.start_row and mark.start_col or 0
      local end_col = code_row == mark.end_row and mark.end_col or #line
      start_col = math.max(0, math.min(start_col, #line))
      end_col = math.max(start_col, math.min(end_col, #line))
      if end_col > start_col and block.rows[code_row + 1] then
        canvas:mark(
          block.rows[code_row + 1],
          #block.prefix + start_col,
          #block.prefix + end_col,
          mark.highlight,
          mark.priority
        )
      end
    end
  end
end

return M
