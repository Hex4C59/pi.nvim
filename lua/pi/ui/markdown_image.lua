local M = {}

local mime_by_extension = {
  bmp = "image/bmp",
  gif = "image/gif",
  jpeg = "image/jpeg",
  jpg = "image/jpeg",
  png = "image/png",
  webp = "image/webp",
}

local path_separator = package.config:sub(1, 1)

local function comparable_path(path)
  path = path:gsub("[/\\]+$", "")
  return path_separator == "\\" and path:lower() or path
end

local function inside_root(root, path)
  root = comparable_path(root)
  path = comparable_path(path)
  if path == root then
    return true
  end
  local next_character = path:sub(#root + 1, #root + 1)
  return path:sub(1, #root) == root and (next_character == "/" or next_character == "\\")
end

local function markdown_destination(value)
  value = vim.trim(value or "")
  local target, remainder
  if value:sub(1, 1) == "<" then
    target, remainder = value:match("^<([^>]+)>%s*(.*)$")
  else
    target, remainder = value:match("^([^%s]+)%s*(.*)$")
  end
  if not target then
    return nil
  end
  if remainder ~= "" and not remainder:match("^[\"'].*[\"']$") and not remainder:match("^%b()$") then
    return nil
  end
  target = target:gsub("\\(.)", "%1")
  if target:find("%", 1, true) and vim.uri_decode then
    local ok, decoded = pcall(vim.uri_decode, target)
    if ok then
      target = decoded
    end
  end
  return target
end

local function absolute_path(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function resolve(root, target)
  if target == "" or target:match("^%a[%w+.-]*:") or target:match("^[/\\][/\\]") then
    return nil
  end
  if target:find("?", 1, true) or target:find("#", 1, true) then
    return nil
  end

  local extension = target:lower():match("%.([%w]+)$")
  local mime_type = extension and mime_by_extension[extension] or nil
  if not mime_type then
    return nil
  end

  local real_root = vim.uv.fs_realpath(vim.fs.normalize(root or ""))
  if not real_root then
    return nil
  end
  local candidate = absolute_path(target) and target or vim.fs.joinpath(real_root, target)
  local real_path = vim.uv.fs_realpath(vim.fs.normalize(candidate))
  local stat = real_path and vim.uv.fs_stat(real_path) or nil
  if not real_path or not stat or stat.type ~= "file" or not inside_root(real_root, real_path) then
    return nil
  end
  return real_path, mime_type
end

local function parse_line(line, root)
  local alt, destination = vim.trim(line or ""):match("^!%[([^%]]*)%]%((.*)%)$")
  local target = alt and markdown_destination(destination) or nil
  if not target then
    return nil
  end
  local path, mime_type = resolve(root, target)
  if not path then
    return nil
  end
  return {
    type = "image",
    path = path,
    mimeType = mime_type,
    alt = alt,
    _pi_markdown_target = target,
    _pi_markdown_replace_line = true,
  }
end

local function closing_parenthesis(line, first)
  local depth = 1
  local escaped = false
  for index = first, #line do
    local character = line:sub(index, index)
    if escaped then
      escaped = false
    elseif character == "\\" then
      escaped = true
    elseif character == "(" then
      depth = depth + 1
    elseif character == ")" then
      depth = depth - 1
      if depth == 0 then
        return index
      end
    end
  end
end

local function inside_inline_code(line, position)
  local ticks = 0
  local escaped = false
  for index = 1, position - 1 do
    local character = line:sub(index, index)
    if escaped then
      escaped = false
    elseif character == "\\" then
      escaped = true
    elseif character == "`" then
      ticks = ticks + 1
    end
  end
  return ticks % 2 == 1
end

local function parse_links(line, root)
  local blocks = {}
  local offset = 1
  while offset <= #line do
    local open = line:find("[", offset, true)
    if not open then
      break
    end
    local close = line:find("](", open + 1, true)
    if not close or inside_inline_code(line, open) then
      offset = open + 1
    else
      local last = closing_parenthesis(line, close + 2)
      if not last then
        offset = open + 1
      else
        local target = markdown_destination(line:sub(close + 2, last - 1))
        local path, mime_type
        if target then
          path, mime_type = resolve(root, target)
        end
        if path then
          local explicit = open > 1 and line:sub(open - 1, open - 1) == "!"
          local syntax_start = explicit and open - 1 or open
          local block = {
            type = "image",
            path = path,
            mimeType = mime_type,
            alt = line:sub(open + 1, close - 1),
            _pi_markdown_target = target,
            _pi_markdown_replace_line = explicit and vim.trim(line) == line:sub(syntax_start, last),
          }
          table.insert(blocks, block)
        end
        offset = last + 1
      end
    end
  end
  return blocks
end

function M.blocks(content_block, root)
  if type(content_block) ~= "table" or content_block.type ~= "text" or type(content_block.text) ~= "string" then
    return {}
  end
  local cache_key = tostring(root or "") .. "\0" .. content_block.text
  local state = content_block._pi_markdown_images
  if state and state.cache_key == cache_key then
    return state.blocks
  end

  local blocks = {}
  local by_line = {}
  local in_fence = false
  local text = vim.trim(content_block.text:gsub("\r\n", "\n"))
  for line_number, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      local line_blocks = parse_links(line, root)
      if #line_blocks > 0 then
        by_line[line_number] = line_blocks
        for _, block in ipairs(line_blocks) do
          block._pi_markdown_line = line_number
          table.insert(blocks, block)
        end
      end
    end
  end
  content_block._pi_markdown_images = {
    cache_key = cache_key,
    blocks = blocks,
    by_line = by_line,
  }
  return blocks
end

function M.at_line(content_block, root, line_number)
  M.blocks(content_block, root)
  local state = content_block and content_block._pi_markdown_images or nil
  local blocks = state and state.by_line[line_number] or nil
  return blocks and blocks[1] or nil
end

function M.at_line_all(content_block, root, line_number)
  M.blocks(content_block, root)
  local state = content_block and content_block._pi_markdown_images or nil
  return (state and state.by_line[line_number]) or {}
end

M._parse_line = parse_line
M._parse_links = parse_links
M._inside_root = inside_root

return M
