local markdown_image = require("pi.ui.markdown_image")
local code = require("pi.ui.render.code")
local media = require("pi.ui.render.media")
local split_lines = require("pi.ui.render.text").split_lines

local M = {}

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

local function add_code_surface_line(canvas, text, opts, text_highlight)
  text = text or ""
  local prefix = opts.prefix or "   "
  local line = prefix .. text
  local margin = (opts.width or 80) >= 8 and 1 or 0
  local target_width = math.max(0, (opts.width or 80) - margin)
  local trailing = math.max(0, target_width - vim.fn.strdisplaywidth(line))
  line = line .. string.rep(" ", trailing)

  local row = canvas:add(line, {
    start_col = margin,
    highlight = "PiCodeBg",
    priority = 90,
  })
  if text_highlight and text ~= "" then
    canvas:mark(row, #prefix, #prefix + #text, text_highlight, 100)
  end
  return row
end

function M.add(canvas, text, opts)
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
        code.apply_highlights(canvas, code_block)
        code_block = nil
        add_code_surface_line(canvas, "", opts)
      else
        add_code_surface_line(canvas, fence, opts, "PiPanelMuted")
        code_block = {
          language = code.normalize_language(fence),
          lines = {},
          rows = {},
          prefix = opts.prefix or "   ",
        }
      end
    elseif code_block then
      table.insert(code_block.lines, line)
      table.insert(code_block.rows, add_code_surface_line(canvas, line, opts, "PiMarkdownCode"))
    elseif #line_images > 0 and line_images[1].block._pi_markdown_replace_line then
      for _, image in ipairs(line_images) do
        media.render(
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
          media.render(
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
    code.apply_highlights(canvas, code_block)
  end
end

return M
