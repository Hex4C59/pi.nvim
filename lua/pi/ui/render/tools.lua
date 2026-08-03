local code = require("pi.ui.render.code")
local media = require("pi.ui.render.media")
local text = require("pi.ui.render.text")
local split_lines = text.split_lines
local single_line = text.single_line
local result_text = text.result_text
local format_duration = text.format_duration
local format_bytes = text.format_bytes
local truncate_display = text.truncate_display

local M = {}

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
      and code.language_for_path((item.args or {}).path)
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
    code.apply_highlights(canvas, code_block)
  end
  local result_content = item.result and item.result.content
  if type(result_content) == "table" then
    for block_index, block in ipairs(result_content) do
      if block.type == "image" then
        canvas:space()
        media.render(canvas, block, "   ", "PiToolSurface", item, block_index, opts)
      end
    end
  end
  return first_row, #canvas.lines
end

function M.render_group(canvas, items, opts)
  canvas:space()
  canvas:add("   Actions", { highlight = "PiToolGroupLabel" })
  local ranges = {}
  for index, item in ipairs(items) do
    local first_row, last_row = render_tool(canvas, item, opts, index == #items)
    table.insert(ranges, { first = first_row, last = last_row, item = item })
  end
  return ranges
end

return M
