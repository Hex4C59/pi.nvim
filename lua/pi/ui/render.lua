local M = {}
local image_data = require("pi.ui.image")
local markdown_image = require("pi.ui.markdown_image")

local Canvas = {}
Canvas.__index = Canvas

function Canvas.new()
  return setmetatable({ lines = {}, marks = {}, images = {} }, Canvas)
end

function Canvas:image(descriptor)
  table.insert(self.images, descriptor)
end

function Canvas:add(text, opts)
  opts = opts or {}
  text = text or ""
  local row = #self.lines
  table.insert(self.lines, text)
  table.insert(self.marks, {
    row = row,
    start_col = opts.start_col or 0,
    end_col = opts.end_col or #text,
    highlight = opts.highlight,
    line_highlight = opts.line_highlight,
    priority = opts.priority,
  })
  return row
end

function Canvas:mark(row, start_col, end_col, highlight, priority)
  table.insert(self.marks, {
    row = row,
    start_col = start_col,
    end_col = end_col,
    highlight = highlight,
    priority = priority,
  })
end

function Canvas:blank(opts)
  self:add("", opts)
end

function Canvas:space()
  if #self.lines > 0 and self.lines[#self.lines] ~= "" then
    self:blank()
  end
end

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(normalized, "\n", { plain = true })
end

local function single_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " ↵ "))
end

local function result_text(result)
  local parts = {}
  for _, block in ipairs((result and result.content) or {}) do
    if block.type == "text" and block.text then
      table.insert(parts, block.text)
    elseif block.type == "omitted" then
      table.insert(parts, "[Image omitted: payload exceeded the client tool output limit]")
    end
  end
  return table.concat(parts, "\n")
end

local function format_hms(total_seconds)
  total_seconds = math.max(0, math.floor(total_seconds))
  local hours = math.floor(total_seconds / 3600)
  local minutes = math.floor((total_seconds % 3600) / 60)
  local seconds = total_seconds % 60

  if hours > 0 then
    return ("%dh %dm %ds"):format(hours, minutes, seconds)
  elseif minutes > 0 then
    return ("%dm %ds"):format(minutes, seconds)
  end
  return ("%ds"):format(seconds)
end

local function format_duration(milliseconds)
  if not milliseconds then
    return nil
  elseif milliseconds < 1000 then
    return ("%dms"):format(milliseconds)
  elseif milliseconds < 60000 then
    return ("%.1fs"):format(milliseconds / 1000)
  end
  return format_hms(milliseconds / 1000)
end

local function format_bytes(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  if bytes >= 1024 * 1024 then
    return ("%.1f MiB"):format(bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return ("%.1f KiB"):format(bytes / 1024)
  end
  return ("%d bytes"):format(bytes)
end

local function format_elapsed(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if seconds < 10 then
    return ("%.1fs"):format(seconds)
  end
  return format_hms(math.floor(seconds + 0.5))
end

local function next_inline_token(text, offset)
  local best = nil
  local function consider(first, last, value, highlight)
    if not first or not value or value == "" then
      return
    end
    if not best or first < best.first or (first == best.first and last > best.last) then
      best = { first = first, last = last, value = value, highlight = highlight }
    end
  end

  local first, last, value = text:find("!%[([^%]]*)%]%([^%)]+%)", offset)
  consider(first, last, value ~= "" and value or "Image", "PiImageFallback")
  first, last, value = text:find("%[([^%]]+)%]%([^%)]+%)", offset)
  consider(first, last, value, "PiMarkdownLink")
  first, last, value = text:find("`([^`]+)`", offset)
  consider(first, last, value, "PiMarkdownInlineCode")
  first, last, value = text:find("%*%*(.-)%*%*", offset)
  consider(first, last, value, "PiMarkdownStrong")
  first, last, value = text:find("__(.-)__", offset)
  consider(first, last, value, "PiMarkdownStrong")
  first, last, value = text:find("%*([^%*]-)%*", offset)
  consider(first, last, value, "PiMarkdownEmphasis")
  return best
end

local function parse_inline(text)
  local output = ""
  local marks = {}
  local offset = 1
  while offset <= #text do
    local token = next_inline_token(text, offset)
    if not token then
      output = output .. text:sub(offset)
      break
    end
    if token.first > offset then
      output = output .. text:sub(offset, token.first - 1)
    end
    local start_col = #output
    output = output .. token.value
    table.insert(marks, {
      start_col = start_col,
      end_col = #output,
      highlight = token.highlight,
    })
    offset = token.last + 1
  end
  return output, marks
end

local function add_inline_line(canvas, prefix, text, opts)
  opts = opts or {}
  local visible, marks = parse_inline(text or "")
  local row = canvas:add(prefix .. visible, {
    highlight = opts.highlight,
    line_highlight = opts.line_highlight,
  })
  for _, mark in ipairs(marks) do
    canvas:mark(row, #prefix + mark.start_col, #prefix + mark.end_col, mark.highlight, 140)
  end
  return row
end

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

local function normalize_code_language(info)
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

local function code_language_for_path(path)
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
  return normalize_code_language(filetype)
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

local function apply_code_highlights(canvas, block)
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

local render_image_block

local function markdown_source_images(opts, line_number)
  local images = opts.content_block and markdown_image.at_line_all(opts.content_block, opts.root, line_number) or {}
  local entries = {}
  for image_index, block in ipairs(images) do
    table.insert(entries, {
      block = block,
      line_number = line_number,
      image_index = image_index,
    })
  end
  return entries
end

local function markdown_block_line(line, images)
  if #images > 0 and images[1].block._pi_markdown_replace_line then
    return true
  end
  if
    line:match("^%s*#+%s+")
    or line:match("^%s*>%s?")
    or line:match("^%s*[-+*]%s+")
    or line:match("^%s*%d+[.)]%s+")
    or line:match("^%s*%*%*[^*]+%*%*%s*$")
    or line:match("^%s*__[^_]+__%s*$")
    or line:match("^    %S")
    or line:match("^%s*|")
    or line:match("|%s*$")
    or line:match("^%s*<[/!%a]")
  then
    return true
  end

  local compact = line:gsub("%s", "")
  return compact:match("^%-%-%-+$") ~= nil or compact:match("^%*%*%*+$") ~= nil or compact:match("^___+$") ~= nil
end

local function strip_markdown_hard_break(line)
  if line:match("  $") then
    return (line:gsub("%s+$", "")), true
  end
  if line:sub(-1) == "\\" then
    return line:sub(1, -2), true
  end
  return line, false
end

-- CommonMark treats a single newline inside a paragraph as a soft break. Keep
-- block syntax as physical rows and let the Neovim window wrap paragraphs.
local function markdown_logical_lines(text, opts)
  local records = {}
  local paragraph = nil
  local in_fence = false

  local function flush_paragraph()
    if paragraph then
      table.insert(records, paragraph)
      paragraph = nil
    end
  end

  local function add_record(line, images)
    table.insert(records, { text = line, images = images })
  end

  for line_number, raw_line in ipairs(split_lines(vim.trim(text or ""))) do
    local images = markdown_source_images(opts, line_number)
    local fence = raw_line:match("^%s*```") ~= nil
    if in_fence or fence then
      flush_paragraph()
      add_record(raw_line, images)
      if fence then
        in_fence = not in_fence
      end
    elseif raw_line:match("^%s*$") then
      flush_paragraph()
      add_record(raw_line, images)
    elseif markdown_block_line(raw_line, images) then
      flush_paragraph()
      add_record(raw_line, images)
    else
      local line, hard_break = strip_markdown_hard_break(raw_line)
      local segment = vim.trim(line)
      if not paragraph then
        paragraph = { text = segment, images = {} }
      elseif segment ~= "" then
        paragraph.text = paragraph.text .. " " .. segment
      end
      vim.list_extend(paragraph.images, images)
      if hard_break then
        flush_paragraph()
      end
    end
  end
  flush_paragraph()
  return records
end

local function add_markdown(canvas, text, opts)
  opts = opts or {}
  local code_block = nil
  for _, record in ipairs(markdown_logical_lines(text, opts)) do
    local line = record.text
    local line_images = record.images
    local fence = line:match("^%s*```%s*(.*)$")
    local heading, heading_text = line:match("^%s*(#+)%s+(.+)$")
    local quote = line:match("^%s*>%s?(.*)$")
    local strong_heading = line:match("^%s*%*%*([^*]+)%*%*%s*$") or line:match("^%s*__([^_]+)__%s*$")
    if fence then
      if code_block then
        apply_code_highlights(canvas, code_block)
        code_block = nil
        canvas:blank({ line_highlight = "PiCodeBg" })
      else
        canvas:add(fence ~= "" and (" " .. fence) or "", {
          highlight = "PiPanelMuted",
          line_highlight = "PiCodeBg",
        })
        code_block = {
          language = normalize_code_language(fence),
          lines = {},
          rows = {},
          prefix = opts.prefix or "   ",
        }
      end
    elseif code_block then
      table.insert(code_block.lines, line)
      table.insert(
        code_block.rows,
        canvas:add(code_block.prefix .. line, {
          highlight = "PiMarkdownCode",
          line_highlight = "PiCodeBg",
        })
      )
    elseif #line_images > 0 and line_images[1].block._pi_markdown_replace_line then
      for _, image in ipairs(line_images) do
        render_image_block(
          canvas,
          image.block,
          opts.prefix or "   ",
          opts.line_highlight,
          opts.item,
          ("%s:%s:%s"):format(opts.block_index, image.line_number, image.image_index),
          opts.render_opts
        )
      end
    elseif heading then
      add_inline_line(canvas, opts.prefix or "   ", heading_text, { highlight = "PiMarkdownHeading" })
    elseif strong_heading then
      add_inline_line(canvas, opts.prefix or "   ", strong_heading, { highlight = "PiMarkdownHeading" })
    elseif quote then
      add_inline_line(canvas, (opts.prefix or "   ") .. "│ ", quote, { highlight = "PiMarkdownQuote" })
    else
      local indent, marker, body = line:match("^(%s*)([-+*])%s+(.+)$")
      if not marker then
        indent, marker, body = line:match("^(%s*)(%d+[.)])%s+(.+)$")
      end
      if marker then
        local prefix = (opts.prefix or " ") .. indent .. marker .. " "
        local row = add_inline_line(canvas, prefix, body, {
          highlight = opts.highlight,
          line_highlight = opts.line_highlight,
        })
        local marker_start = #(opts.prefix or " ") + #indent
        canvas:mark(row, marker_start, marker_start + #marker, "PiMarkdownListMarker", 145)
      else
        add_inline_line(canvas, opts.prefix or " ", line, {
          highlight = opts.highlight,
          line_highlight = opts.line_highlight,
        })
      end
    end
    if not code_block then
      for _, image in ipairs(line_images) do
        if not image.block._pi_markdown_replace_line then
          render_image_block(
            canvas,
            image.block,
            opts.prefix or "   ",
            opts.line_highlight,
            opts.item,
            ("%s:%s:%s"):format(opts.block_index, image.line_number, image.image_index),
            opts.render_opts
          )
        end
      end
    end
  end
  if code_block then
    apply_code_highlights(canvas, code_block)
  end
end

local function item_identity(item, opts)
  return tostring(item._pi_id or item.id or (opts.item_ids and opts.item_ids[item]) or "item")
end

render_image_block = function(canvas, block, prefix, line_highlight, item, block_index, opts)
  prefix = prefix or "   "
  line_highlight = line_highlight or "PiCanvasNormal"
  local prepared = image_data.prepared(block)
  local preview = image_data.preview(block)
  if opts.image_terminal and prepared then
    local first_row = canvas:add(prefix .. string.rep(" ", prepared.width), {
      highlight = "PiImageSurface",
      line_highlight = line_highlight,
    })
    canvas:image({
      key = table.concat({ item_identity(item, opts), tostring(block_index), prepared.key }, ":"),
      content_key = prepared.key,
      block = block,
      path = prepared.path,
      row = first_row,
      col = #prefix,
      width = prepared.width,
      height = prepared.height,
      range_height = 1,
      conceal = true,
    })
    return first_row
  elseif preview then
    local first_row
    for index, preview_row in ipairs(preview.rows) do
      local row_prefix = index == 1 and prefix or string.rep(" ", #prefix)
      local row = canvas:add(row_prefix .. preview_row.text, { line_highlight = line_highlight })
      first_row = first_row or row
      for _, mark in ipairs(preview_row.marks) do
        canvas:mark(row, #row_prefix + mark.start_col, #row_prefix + mark.end_col, mark.highlight, 150)
      end
    end
    if first_row and prepared then
      canvas:image({
        key = table.concat({ item_identity(item, opts), tostring(block_index), prepared.key, "preview" }, ":"),
        content_key = prepared.key,
        block = block,
        path = prepared.path,
        row = first_row,
        col = #prefix,
        width = prepared.width,
        height = prepared.height,
        range_height = prepared.height,
        mode = "blocks",
      })
    end
    return first_row
  else
    local row = canvas:add(prefix .. image_data.fallback(block), {
      highlight = "PiImageFallback",
      line_highlight = line_highlight,
    })
    return row
  end
end

local function render_user(canvas, item, opts)
  canvas:space()
  local lines = split_lines(item.text)
  local images = {}
  if type(item.content) == "table" then
    for block_index, block in ipairs(item.content) do
      if block.type == "image" then
        table.insert(images, { block = block, index = block_index })
      end
    end
  end
  local rendered = false
  for index, line in ipairs(lines) do
    local prefix = index == 1 and " › " or "   "
    local row = canvas:add(prefix .. line, {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
    if index == 1 then
      canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    end
    rendered = true
  end
  for index, entry in ipairs(images) do
    local prefix = not rendered and index == 1 and " › " or "   "
    local row = render_image_block(canvas, entry.block, prefix, "PiUserMessageBg", item, entry.index, opts)
    if not rendered and index == 1 and row then
      canvas:mark(row, 1, 1 + #"›", "PiUserLabel", 140)
    end
    rendered = true
  end
  if not rendered then
    canvas:add(" › ", {
      highlight = "PiUserMessageText",
      line_highlight = "PiUserMessageBg",
    })
  end
end

local function has_visible_after(content, index)
  for next_index = index + 1, #content do
    local block = content[next_index]
    if
      (block.type == "text" and vim.trim(block.text or "") ~= "")
      or (block.type == "thinking" and vim.trim(block.thinking or "") ~= "")
      or block.type == "image"
    then
      return true
    end
  end
  return false
end

local function render_assistant_meta(canvas, has_thinking, duration_ms)
  if not has_thinking then
    return
  end

  local duration = format_duration(duration_ms)
  local text = duration and ("Thought for " .. duration) or "Thinking..."
  canvas:add("   " .. text, { highlight = "PiProcessSummary" })
end

local function render_assistant(canvas, item, opts)
  local message = item.message or {}
  local content = message.content or {}
  local visible = false
  local has_thinking = false
  for _, block in ipairs(content) do
    if
      (block.type == "text" and vim.trim(block.text or "") ~= "")
      or (block.type == "thinking" and vim.trim(block.thinking or "") ~= "")
      or block.type == "image"
    then
      visible = true
      has_thinking = has_thinking or block.type == "thinking"
    end
  end
  if visible then
    canvas:space()
    render_assistant_meta(canvas, has_thinking, item.duration_ms)
  end

  for index, block in ipairs(content) do
    if block.type == "thinking" and vim.trim(block.thinking or "") ~= "" then
      if not opts.hide_thinking then
        add_markdown(canvas, block.thinking, { highlight = "PiThinkingText", prefix = "   ┊ " })
        if has_visible_after(content, index) then
          canvas:blank()
        end
      end
    elseif block.type == "text" and vim.trim(block.text or "") ~= "" then
      add_markdown(canvas, block.text, {
        prefix = "   ",
        content_block = block,
        root = opts.root,
        item = item,
        block_index = index,
        render_opts = opts,
      })
    elseif block.type == "image" then
      render_image_block(canvas, block, "   ", nil, item, index, opts)
    end
  end

  if message.stopReason == "aborted" then
    canvas:blank()
    canvas:add(" Operation aborted", { highlight = "PiToolError" })
  elseif message.stopReason == "length" then
    canvas:blank()
    canvas:add(" Response stopped at the model output limit", { highlight = "PiToolError" })
  elseif message.stopReason == "error" then
    canvas:blank()
    local error_lines = split_lines(message.errorMessage or "")
    if #error_lines == 0 then
      error_lines = { "Unknown error" }
    end
    for index, line in ipairs(error_lines) do
      local prefix = index == 1 and " Error: " or string.rep(" ", #" Error: ")
      canvas:add(prefix .. line, { highlight = "PiToolError" })
    end
  end
end

local function tool_subject(item)
  local args = item.args or {}
  if item.name == "bash" then
    return args.command or ""
  elseif item.name == "read" then
    local path = args.path or ""
    if args.offset then
      path = path .. ":" .. tostring(args.offset)
    end
    return path
  elseif item.name == "write" then
    return args.path or ""
  elseif item.name == "edit" then
    return args.path or ""
  elseif item.name == "grep" then
    local query = args.pattern or args.query or ""
    return args.path and (query .. " in " .. args.path) or query
  elseif item.name == "find" then
    local pattern = args.pattern or args.glob or ""
    return args.path and (pattern .. " in " .. args.path) or pattern
  elseif item.name == "ls" then
    return args.path or "."
  end
  local ok, encoded = pcall(vim.json.encode, args)
  if not ok or encoded == "{}" then
    return item.name
  end
  if #encoded > 160 then
    encoded = encoded:sub(1, 157) .. "..."
  end
  return item.name .. "  " .. encoded
end

local function tool_verb(item)
  if item.error then
    return "Failed"
  end
  local verbs = {
    bash = { "Running", "Ran" },
    read = { "Reading", "Read" },
    grep = { "Searching", "Searched" },
    find = { "Searching", "Searched" },
    ls = { "Listing", "Listed" },
    edit = { "Editing", "Edited" },
    write = { "Writing", "Wrote" },
  }
  local pair = verbs[item.name]
  if not pair then
    return item.state == "pending" and "Using" or "Used"
  end
  return item.state == "pending" and pair[1] or pair[2]
end

local function truncate_display(text, width)
  text = single_line(text)
  width = math.max(1, width or 80)
  if vim.api.nvim_strwidth(text) <= width then
    return text
  end
  if width <= 3 then
    return string.rep(".", width)
  end
  local target = width - 3
  local result = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local candidate = result .. vim.fn.strcharpart(text, index, 1)
    if vim.api.nvim_strwidth(candidate) > target then
      break
    end
    result = candidate
  end
  return result .. "..."
end

local function add_tool_row(canvas, entry, last_in_group, width, expanded)
  local prefix = last_in_group and "      " or "   │  "
  local available_width = math.max(1, (width or 80) - vim.api.nvim_strwidth(prefix) - 2)
  local entry_text = single_line(entry.text)
  local text = expanded and entry_text or truncate_display(entry_text, available_width)
  local trailing = math.max(0, available_width - vim.api.nvim_strwidth(text))
  local line = prefix .. text .. string.rep(" ", trailing)
  local row = canvas:add(line)
  canvas:mark(row, 0, #prefix, "PiToolGutter", 130)
  canvas:mark(row, #prefix, #line, entry.line_highlight or "PiToolSurface", 80)
  canvas:mark(row, #prefix, #prefix + #text, entry.highlight, 140)
  return row, prefix
end

local function omitted_entry(count, noun)
  return {
    text = ("… %d %s hidden · Ctrl-O expand"):format(count, noun or "lines"),
    highlight = "PiToolOmitted",
  }
end

local function collapsed_entries(entries, maximum, noun)
  if #entries <= maximum then
    return entries
  end
  local head = math.floor(maximum / 2)
  local tail = maximum - head - 1
  local result = {}
  for index = 1, head do
    table.insert(result, entries[index])
  end
  table.insert(result, omitted_entry(#entries - head - tail, noun))
  for index = #entries - tail + 1, #entries do
    table.insert(result, entries[index])
  end
  return result
end

local function tail_entries(entries, maximum, noun)
  if #entries <= maximum then
    return entries
  end
  local result = { omitted_entry(#entries - maximum + 1, noun) }
  for index = #entries - maximum + 2, #entries do
    table.insert(result, entries[index])
  end
  return result
end

local function output_entries(lines, item, expanded)
  local entries = {}
  for _, line in ipairs(lines) do
    table.insert(entries, { text = line, highlight = "PiToolOutput" })
  end
  if expanded then
    if #entries <= 240 then
      return entries
    end
    local result = {}
    for index = 1, 239 do
      table.insert(result, entries[index])
    end
    table.insert(result, {
      text = ("… %d more lines"):format(#entries - 239),
      highlight = "PiToolOmitted",
    })
    return result
  elseif item.state == "pending" or item.error then
    return tail_entries(entries, item.error and 8 or 5)
  end
  return collapsed_entries(entries, 5)
end

local function item_edits(item)
  local args = item.args or {}
  if type(args.edits) == "table" and #args.edits > 0 then
    return args.edits
  end
  if args.oldText ~= nil or args.newText ~= nil then
    return { { oldText = args.oldText or "", newText = args.newText or "" } }
  end
  if args.old_string ~= nil or args.new_string ~= nil then
    return { { oldText = args.old_string or "", newText = args.new_string or "" } }
  end
  return {}
end

local function edit_entries(item)
  local entries = {}
  for _, edit in ipairs(item_edits(item)) do
    for _, line in ipairs(split_lines(edit.oldText)) do
      table.insert(entries, {
        text = "- " .. line,
        highlight = "PiDiffDelete",
        line_highlight = "PiDiffDeleteLine",
      })
    end
    for _, line in ipairs(split_lines(edit.newText)) do
      table.insert(entries, {
        text = "+ " .. line,
        highlight = "PiDiffAdd",
        line_highlight = "PiDiffAddLine",
      })
    end
  end
  return entries
end

local function write_entries(item)
  local entries = {}
  for _, line in ipairs(split_lines((item.args and item.args.content) or "")) do
    table.insert(entries, {
      text = "+ " .. line,
      highlight = "PiDiffAdd",
      line_highlight = "PiDiffAddLine",
    })
  end
  return entries
end

local function diff_counts(item)
  local additions = 0
  local deletions = 0
  if item.name == "edit" then
    for _, edit in ipairs(item_edits(item)) do
      additions = additions + #split_lines(edit.newText)
      deletions = deletions + #split_lines(edit.oldText)
    end
  elseif item.name == "write" then
    additions = #split_lines((item.args and item.args.content) or "")
  end
  return additions, deletions
end

local function render_tool_header(canvas, item, opts, last_in_group)
  local pending = item.state == "pending"
  local bullet = item.error and "×" or pending and "◌" or "✓"
  local status_highlight = item.error and "PiToolFailed" or pending and "PiToolRunning" or "PiToolSuccess"
  local verb = tool_verb(item)
  local subject = single_line(tool_subject(item))
  if (opts.width or 80) < 60 and subject ~= "" and vim.tbl_contains({ "read", "write", "edit", "ls" }, item.name) then
    subject = vim.fs.basename(subject)
  end
  if item.error then
    subject = item.name .. (subject ~= "" and ("  " .. subject) or "")
  end
  local header = ""
  local marks = {}
  local function append(text, highlight)
    local start_col = #header
    header = header .. text
    if highlight then
      table.insert(marks, { start_col = start_col, end_col = #header, highlight = highlight })
    end
  end

  append(last_in_group and "   ╰─ " or "   ├─ ", "PiToolGutter")
  append(bullet, status_highlight)
  append(" ")
  append(verb, "PiToolVerb")
  if subject ~= "" then
    append("  ")
    local subject_highlight = vim.tbl_contains({ "read", "write", "edit", "grep", "find", "ls" }, item.name)
        and "PiToolSubject"
      or "PiToolCommand"
    append(subject, subject_highlight)
  end
  if not item.error and (item.name == "edit" or item.name == "write") then
    local additions, deletions = diff_counts(item)
    if additions > 0 or deletions > 0 then
      append("  ")
      append("+" .. additions, "PiDiffAdd")
      if deletions > 0 then
        append(" ")
        append("-" .. deletions, "PiDiffDelete")
      end
    end
  end
  local duration = format_duration(item.duration_ms)
  local hide_duration = (opts.width or 80) < 60 and (item.name == "edit" or item.name == "write")
  if duration and not hide_duration then
    append("  ·  " .. duration, "PiPanelMuted")
  end

  local visible = truncate_display(header, math.max(8, (opts.width or 80) - 1))
  local row = canvas:add(visible, { highlight = "PiToolCommand" })
  for _, mark in ipairs(marks) do
    local end_col = math.min(mark.end_col, #visible)
    if end_col > mark.start_col then
      canvas:mark(row, mark.start_col, end_col, mark.highlight, 140)
    end
  end
end

local function render_tool(canvas, item, opts, last_in_group)
  local first_row = #canvas.lines + 1
  local expanded = item.expanded
  if expanded == nil then
    expanded = opts.tools_expanded == true
  end
  render_tool_header(canvas, item, opts, last_in_group)

  local entries = {}
  if item.name == "edit" and not item.error then
    entries = edit_entries(item)
    if expanded and #entries > 160 then
      local limited = {}
      for index = 1, 159 do
        table.insert(limited, entries[index])
      end
      table.insert(limited, {
        text = ("… %d more diff lines"):format(#entries - 159),
        highlight = "PiToolOmitted",
      })
      entries = limited
    elseif not expanded then
      entries = collapsed_entries(entries, 8, "diff lines")
    end
  elseif item.name == "write" and item.args and item.args.content and not item.error then
    entries = write_entries(item)
    if expanded and #entries > 160 then
      entries = collapsed_entries(entries, 160, "lines")
    elseif not expanded then
      entries = collapsed_entries(entries, 6, "lines")
    end
  end

  local output = result_text(item.result)
  local output_lines = split_lines(output)
  if item.name == "read" and output ~= "" and not expanded and not item.error then
    entries = {
      {
        text = ("%d line%s · Ctrl-O expand"):format(#output_lines, #output_lines == 1 and "" or "s"),
        highlight = "PiToolOmitted",
      },
    }
  elseif output ~= "" and ((item.name ~= "edit" and item.name ~= "write") or item.error or #entries == 0) then
    vim.list_extend(entries, output_entries(output_lines, item, expanded))
  end

  local details = item.result and item.result.details or nil
  if item.output_released then
    table.insert(entries, {
      text = "Earlier output released from memory",
      highlight = "PiToolOmitted",
    })
  end
  if item.args_truncated then
    table.insert(entries, {
      text = item.args_released and "Earlier tool input released from memory"
        or ("Client tool input limit omitted %s"):format(format_bytes(item.args_omitted_bytes or 0)),
      highlight = "PiToolOmitted",
    })
  end
  if item.name == "bash" and details and details.clientTruncated then
    local retained = details.clientRetainedBytes or 0
    local omitted = details.clientOmittedBytes or 0
    table.insert(entries, {
      text = ("Client retained the last %s; %s omitted"):format(format_bytes(retained), format_bytes(omitted)),
      highlight = "PiToolOmitted",
    })
  elseif details and details.clientTruncated then
    table.insert(entries, {
      text = ("Client output limit omitted %s"):format(format_bytes(details.clientOmittedBytes or 0)),
      highlight = "PiToolOmitted",
    })
  end
  if item.name == "bash" and details and details.truncated then
    table.insert(entries, {
      text = details.fullOutputPath and ("Full output: " .. details.fullOutputPath)
        or "Streamed output preserved; final response was truncated",
      highlight = "PiToolOmitted",
    })
  end

  local read_language = item.name == "read"
      and expanded
      and not item.error
      and code_language_for_path((item.args or {}).path)
    or nil
  local code_block = read_language and { language = read_language, lines = {}, rows = {} } or nil
  for _, entry in ipairs(entries) do
    local row, prefix = add_tool_row(canvas, entry, last_in_group, opts.width, expanded)
    if code_block and entry.highlight == "PiToolOutput" then
      code_block.prefix = prefix
      table.insert(code_block.lines, entry.text)
      table.insert(code_block.rows, row)
    end
  end
  if code_block and #code_block.lines > 0 then
    apply_code_highlights(canvas, code_block)
  end
  local result_content = item.result and item.result.content
  if type(result_content) == "table" then
    for block_index, block in ipairs(result_content) do
      if block.type == "image" then
        canvas:space()
        render_image_block(canvas, block, "   ", "PiToolSurface", item, block_index, opts)
      end
    end
  end
  return first_row, #canvas.lines
end

local function render_tool_group(canvas, items, opts)
  canvas:space()
  canvas:add("   Actions", { highlight = "PiToolGroupLabel" })
  local ranges = {}
  for index, item in ipairs(items) do
    local first_row, last_row = render_tool(canvas, item, opts, index == #items)
    table.insert(ranges, { first = first_row, last = last_row, item = item })
  end
  return ranges
end

local function render_status(canvas, item)
  canvas:space()
  add_markdown(canvas, item.text, {
    highlight = item.error and "PiToolError" or "PiPanelMuted",
  })
end

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
  for _, block in ipairs((item.message or {}).content or {}) do
    if block.type == "thinking" and vim.trim(block.thinking or "") ~= "" then
      return true
    end
  end
  return false
end

local function public_assistant(item)
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

local function render_item_range(canvas, items, first, last, opts, tool_ranges)
  local index = first
  while index <= last do
    local item = items[index]
    if item.type == "tool" then
      local group = {}
      while index <= last and items[index].type == "tool" do
        table.insert(group, items[index])
        index = index + 1
      end
      vim.list_extend(tool_ranges, render_tool_group(canvas, group, opts))
    else
      if item.type == "user" then
        render_user(canvas, item, opts)
      elseif item.type == "assistant" then
        render_assistant(canvas, item, opts)
      elseif item.type == "status" then
        render_status(canvas, item)
      end
      index = index + 1
    end
  end
end

local function render_compact_process(canvas, items, first, last, opts, process_ranges)
  local summary = process_summary(items, first, last)
  if not summary then
    render_item_range(canvas, items, first, last, opts, {})
    return
  end

  for index = first, last do
    local item = items[index]
    if item.type == "assistant" then
      local public_item = public_assistant(item)
      if public_item then
        render_assistant(canvas, public_item, opts)
      end
    elseif item.type == "status" then
      render_status(canvas, item)
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

local function render_process_segments(canvas, items, first, last, opts, active, tool_ranges, process_ranges)
  local segments = process_segments(items, first, last)
  for index, segment in ipairs(segments) do
    if active and index == #segments then
      local detail_opts = vim.tbl_extend("force", {}, opts, {
        hide_thinking = false,
        tools_expanded = opts.tools_expanded == true,
      })
      render_item_range(canvas, items, segment.first, segment.last, detail_opts, tool_ranges)
    else
      render_compact_process(canvas, items, segment.first, segment.last, opts, process_ranges)
    end
  end
end

local function add_welcome_row(canvas, left, inner_width, text, marks)
  local side_padding = inner_width >= 8 and 2 or 0
  local content_width = math.max(0, inner_width - side_padding * 2)
  local visible = content_width > 0 and truncate_display(text or "", content_width) or ""
  local trailing = math.max(0, content_width - vim.api.nvim_strwidth(visible))
  local content = string.rep(" ", side_padding) .. visible .. string.rep(" ", trailing + side_padding)
  local row = canvas:add(left .. "│" .. content .. "│", { highlight = "PiWelcomeBorder" })
  local content_start = #left + #"│" + side_padding

  for _, mark in ipairs(marks or {}) do
    local start_col = math.min(mark.start_col or 0, #visible)
    local end_col = math.min(mark.end_col or #visible, #visible)
    if end_col > start_col then
      canvas:mark(row, content_start + start_col, content_start + end_col, mark.highlight, 130)
    end
  end
end

local function fit_welcome_cell(text, width, opts)
  opts = opts or {}
  width = math.max(0, width or 0)
  local padding = math.min(opts.padding or 2, math.floor(width / 2))
  local content_width = math.max(0, width - padding * 2)
  local visible = content_width > 0 and truncate_display(text or "", content_width) or ""
  local remaining = math.max(0, content_width - vim.api.nvim_strwidth(visible))
  local leading = padding
  local trailing = padding + remaining

  if opts.align == "center" then
    local before = math.floor(remaining / 2)
    leading = leading + before
    trailing = trailing - before
  end

  return string.rep(" ", leading) .. visible .. string.rep(" ", trailing), visible, leading
end

local function mark_welcome_text(canvas, row, offset, visible, marks)
  for _, mark in ipairs(marks or {}) do
    local start_col = math.min(mark.start_col or 0, #visible)
    local end_col = math.min(mark.end_col or #visible, #visible)
    if end_col > start_col then
      canvas:mark(row, offset + start_col, offset + end_col, mark.highlight, 130)
    end
  end
end

local function add_welcome_split_row(canvas, left_width, right_width, left_text, left_marks, right_text, right_marks)
  local left_cell, left_visible, left_padding = fit_welcome_cell(left_text, left_width, {
    align = "center",
    padding = 0,
  })
  local right_cell, right_visible, right_padding = fit_welcome_cell(right_text, right_width)
  local left_edge = "│"
  local middle = "│"
  local row = canvas:add(left_edge .. left_cell .. middle .. right_cell .. "│", {
    highlight = "PiWelcomeBorder",
  })

  mark_welcome_text(canvas, row, #left_edge + left_padding, left_visible, left_marks)
  mark_welcome_text(canvas, row, #(left_edge .. left_cell .. middle) + right_padding, right_visible, right_marks)
end

local function add_welcome_split_divider(canvas, left_width, right_width, left_text, left_marks)
  local left_cell, left_visible, left_padding = fit_welcome_cell(left_text, left_width, {
    align = "center",
    padding = 0,
  })
  local left_edge = "│"
  local row = canvas:add(left_edge .. left_cell .. "├" .. string.rep("─", right_width) .. "┤", {
    highlight = "PiWelcomeBorder",
  })
  mark_welcome_text(canvas, row, #left_edge + left_padding, left_visible, left_marks)
end

local function add_welcome_top_border(canvas, left_width, right_width)
  local prefix = "─ "
  local brand = "PI"
  local separator = " · "
  local agent = "coding agent"
  local suffix = " "
  local title = prefix .. brand .. separator .. agent .. suffix
  local segment_width = right_width and left_width or left_width
  local title_width = vim.api.nvim_strwidth(title)
  local segment
  local show_title = title_width <= segment_width

  if show_title then
    segment = title .. string.rep("─", segment_width - title_width)
  else
    segment = string.rep("─", segment_width)
  end

  local line
  if right_width then
    line = "╭" .. segment .. "┬" .. string.rep("─", right_width) .. "╮"
  else
    line = "╭" .. segment .. "╮"
  end
  local row = canvas:add(line, { highlight = "PiWelcomeBorder" })
  if show_title then
    local title_start = #"╭" + #prefix
    canvas:mark(row, title_start, title_start + #brand, "PiWelcomeTitle", 140)
    local agent_start = title_start + #brand + #separator
    canvas:mark(row, agent_start, agent_start + #agent, "PiWelcomeAgent", 140)
  end
end

local function welcome_brand_rows()
  local brand_width = 25
  local function align_brand(text)
    return text .. string.rep(" ", math.max(0, brand_width - vim.api.nvim_strwidth(text)))
  end

  local cap_segment = "███"
  local cap = cap_segment:rep(4)
  local title_gap = "   "
  local cap_line = cap .. title_gap .. "PI"
  local cap_marks = {
    { start_col = 0, end_col = #cap_segment, highlight = "PiWelcomeLogo1" },
    { start_col = #cap_segment, end_col = #cap_segment * 2, highlight = "PiWelcomeLogo2" },
    { start_col = #cap_segment * 2, end_col = #cap_segment * 3, highlight = "PiWelcomeLogo3" },
    { start_col = #cap_segment * 3, end_col = #cap, highlight = "PiWelcomeLogo4" },
    { start_col = #cap + #title_gap, end_col = #cap_line, highlight = "PiWelcomeTitle" },
  }

  local stem = "   ██  ██"
  local first_leg_start = #"   "
  local first_leg_end = first_leg_start + #"██"
  local second_leg_start = first_leg_end + #"  "
  local second_leg_end = second_leg_start + #"██"
  local stem_marks = {
    { start_col = first_leg_start, end_col = first_leg_end, highlight = "PiWelcomeLogo2" },
    { start_col = second_leg_start, end_col = second_leg_end, highlight = "PiWelcomeLogo4" },
  }
  local tagline_gap = "    "
  local agent_line = stem .. tagline_gap .. "coding agent"
  local agent_marks = vim.deepcopy(stem_marks)
  table.insert(agent_marks, {
    start_col = #stem + #tagline_gap,
    end_col = #agent_line,
    highlight = "PiWelcomeAgent",
  })
  local neovim_line = stem .. tagline_gap .. "for Neovim"
  local neovim_marks = vim.deepcopy(stem_marks)
  table.insert(neovim_marks, {
    start_col = #stem + #tagline_gap,
    end_col = #neovim_line,
    highlight = "PiWelcomeNeovim",
  })

  return {
    { text = align_brand(cap_line), marks = cap_marks },
    { text = align_brand(agent_line), marks = agent_marks },
    { text = align_brand(neovim_line), marks = neovim_marks },
    { text = align_brand(stem), marks = stem_marks },
  }
end

local function welcome_detail(label, value, highlight)
  local label_width = 13
  local label_text = label .. string.rep(" ", math.max(1, label_width - #label))
  local text = label_text .. value
  return text,
    {
      { start_col = 0, end_col = #label_text, highlight = "PiWelcomeLabel" },
      { start_col = #label_text, end_col = #text, highlight = highlight },
    }
end

local function welcome_model_detail(model, thinking)
  local label_width = 13
  local label_text = "model" .. string.rep(" ", label_width - #"model")
  if model == "loading" then
    local text = label_text .. "connecting..."
    return text,
      {
        { start_col = 0, end_col = #label_text, highlight = "PiWelcomeLabel" },
        { start_col = #label_text, end_col = #text, highlight = "PiWelcomeModelValue" },
      }
  end

  local separator = " · "
  local text = label_text .. model .. separator .. thinking
  local model_end = #label_text + #model
  local thinking_start = model_end + #separator
  return text,
    {
      { start_col = 0, end_col = #label_text, highlight = "PiWelcomeLabel" },
      { start_col = #label_text, end_col = model_end, highlight = "PiWelcomeModelValue" },
      { start_col = model_end, end_col = thinking_start, highlight = "PiWelcomeLabel" },
      { start_col = thinking_start, end_col = #text, highlight = "PiWelcomeThinkingValue" },
    }
end

local function render_welcome(canvas, opts)
  opts = opts or {}
  local width = math.max(2, opts.width or 80)
  local inner_width = math.max(0, width - 2)
  local left = ""
  local model = opts.model or "loading"
  local thinking = opts.thinking or "-"
  local text, marks = welcome_model_detail(model, thinking)
  local model_row = { text = text, marks = marks }

  local project = vim.fn.fnamemodify(opts.root or vim.uv.cwd() or "", ":~")
  local project_row = {
    text = project,
    marks = {
      { start_col = 0, end_col = #project, highlight = "PiWelcomeProjectValue" },
    },
  }

  local permission_labels = {
    confirm = "manual",
    manual = "manual",
    acceptEdits = "accept edits",
    ["accept-edits"] = "accept edits",
    auto = "auto",
    plan = "plan",
    ["read-only"] = "workspace read only",
    full = "full access",
  }
  local permission = opts.permission or "confirm"
  local security = opts.security
  if security == "read-only" then
    permission = "read-only"
  elseif security == "full" then
    permission = "full"
  end
  text, marks = welcome_detail(
    "permissions",
    permission_labels[permission] or permission,
    permission == "full" and "PiWelcomePermissionDanger"
      or permission == "read-only" and "PiWelcomePermissionSafe"
      or permission == "plan" and "PiWelcomePermissionSafe"
      or permission == "auto" and "PiWelcomePermissionWarning"
      or "PiWelcomePermissionValue"
  )
  local permission_row = { text = text, marks = marks }
  local brand_rows = welcome_brand_rows()

  if width >= 72 then
    local split_width = width - 3
    local left_width = math.min(38, math.max(29, math.floor(split_width * 0.34)))
    local right_width = split_width - left_width
    add_welcome_top_border(canvas, left_width, right_width)
    add_welcome_split_row(canvas, left_width, right_width, "", nil, "", nil)
    add_welcome_split_row(canvas, left_width, right_width, brand_rows[1].text, brand_rows[1].marks, "Session", {
      { start_col = 0, end_col = #"Session", highlight = "PiWelcomeSection" },
    })
    add_welcome_split_row(
      canvas,
      left_width,
      right_width,
      brand_rows[2].text,
      brand_rows[2].marks,
      model_row.text,
      model_row.marks
    )
    add_welcome_split_row(
      canvas,
      left_width,
      right_width,
      brand_rows[3].text,
      brand_rows[3].marks,
      permission_row.text,
      permission_row.marks
    )
    add_welcome_split_divider(canvas, left_width, right_width, brand_rows[4].text, brand_rows[4].marks)
    add_welcome_split_row(canvas, left_width, right_width, "", nil, "Workspace", {
      { start_col = 0, end_col = #"Workspace", highlight = "PiWelcomeSection" },
    })
    add_welcome_split_row(canvas, left_width, right_width, "", nil, project_row.text, project_row.marks)
    add_welcome_split_row(canvas, left_width, right_width, "", nil, "", nil)
    canvas:add("╰" .. string.rep("─", left_width) .. "┴" .. string.rep("─", right_width) .. "╯", {
      highlight = "PiWelcomeBorder",
    })
    return
  end

  add_welcome_top_border(canvas, inner_width)
  add_welcome_row(canvas, left, inner_width, "")
  for _, row in ipairs(brand_rows) do
    add_welcome_row(canvas, left, inner_width, row.text, row.marks)
  end
  add_welcome_row(canvas, left, inner_width, "")
  add_welcome_row(canvas, left, inner_width, "Session", {
    { start_col = 0, end_col = #"Session", highlight = "PiWelcomeSection" },
  })
  add_welcome_row(canvas, left, inner_width, model_row.text, model_row.marks)
  add_welcome_row(canvas, left, inner_width, permission_row.text, permission_row.marks)
  add_welcome_row(canvas, left, inner_width, "")
  add_welcome_row(canvas, left, inner_width, "Workspace", {
    { start_col = 0, end_col = #"Workspace", highlight = "PiWelcomeSection" },
  })
  add_welcome_row(canvas, left, inner_width, project_row.text, project_row.marks)
  add_welcome_row(canvas, left, inner_width, "")
  canvas:add(left .. "╰" .. string.rep("─", inner_width) .. "╯", { highlight = "PiWelcomeBorder" })
end

function M.render_welcome(opts)
  local canvas = Canvas.new()
  render_welcome(canvas, opts)
  return canvas.lines, canvas.marks
end

function M.render(items, opts)
  opts = opts or {}
  opts = vim.tbl_extend("force", {}, opts)
  opts.item_ids = {}
  for index, item in ipairs(items) do
    opts.item_ids[item] = index
  end
  local canvas = Canvas.new()
  local tool_ranges = {}
  local process_ranges = {}
  if opts.welcome then
    render_welcome(canvas, vim.tbl_extend("force", { width = opts.width }, opts.welcome))
  end

  if not opts.collapse_processes then
    render_item_range(canvas, items, 1, #items, opts, tool_ranges)
    return canvas.lines, canvas.marks, tool_ranges, process_ranges, canvas.images
  end

  local index = 1
  while index <= #items do
    local item = items[index]
    if item.type == "user" then
      render_user(canvas, item, opts)
      local turn_first = index + 1
      local next_turn = turn_first
      while next_turn <= #items and items[next_turn].type ~= "user" do
        next_turn = next_turn + 1
      end
      local turn_last = next_turn - 1
      local active = opts.process_active == true and next_turn > #items

      if turn_first <= turn_last then
        if opts.process_expanded == true then
          local detail_opts = vim.tbl_extend("force", {}, opts, {
            hide_thinking = false,
            tools_expanded = true,
          })
          render_item_range(canvas, items, turn_first, turn_last, detail_opts, tool_ranges)
        else
          render_process_segments(canvas, items, turn_first, turn_last, opts, active, tool_ranges, process_ranges)
        end
      end
      index = next_turn
    else
      local range_last = index
      while range_last + 1 <= #items and items[range_last + 1].type ~= "user" do
        range_last = range_last + 1
      end
      render_item_range(canvas, items, index, range_last, opts, tool_ranges)
      index = range_last + 1
    end
  end

  return canvas.lines, canvas.marks, tool_ranges, process_ranges, canvas.images
end

M.split_lines = split_lines
M.result_text = result_text
M.format_duration = format_duration
M.format_elapsed = format_elapsed
return M
