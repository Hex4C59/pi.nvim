local Canvas = require("pi.ui.render.canvas").Canvas
local truncate_display = require("pi.ui.render.text").truncate_display

local M = {}

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

function M.render_into(canvas, opts)
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

function M.render(opts)
  local canvas = Canvas.new()
  M.render_into(canvas, opts)
  return canvas.lines, canvas.marks
end

return M
