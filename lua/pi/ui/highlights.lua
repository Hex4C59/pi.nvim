local M = {}

local welcome_palette = {}
local welcome_background = nil

local function blend(foreground, background, amount)
  if not foreground or not background then
    return foreground or background
  end
  local function channel(value, shift)
    return math.floor(value / (2 ^ shift)) % 256
  end
  local function mixed(shift)
    return math.floor(channel(background, shift) * (1 - amount) + channel(foreground, shift) * amount + 0.5)
  end
  return mixed(16) * 0x10000 + mixed(8) * 0x100 + mixed(0)
end

local function setup()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  local ok = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false })
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  local err = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  local hint = vim.api.nvim_get_hl(0, { name = "DiagnosticHint", link = false })
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
  local func = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
  local separator = vim.api.nvim_get_hl(0, { name = "WinSeparator", link = false })
  local background = normal.bg or 0x1e1e1e
  local foreground = normal.fg or 0xd4d4d4
  local canvas = blend(0x000000, background, 0.2)
  local muted = comment.fg or blend(foreground, canvas, 0.5)
  local accent = info.fg or 0x7aa2f7
  local success = ok.fg or 0x9ece6a
  local warning = warn.fg or 0xe0af68
  local error_color = err.fg or 0xf7768e
  local palette = {}
  local seen_colors = {}
  local function add_palette_color(color)
    if #palette < 4 and color and not seen_colors[color] then
      table.insert(palette, color)
      seen_colors[color] = true
    end
  end
  for _, color in ipairs({ accent, success, warning }) do
    add_palette_color(color)
  end
  for _, highlight in ipairs({ hint, special, func, string_hl }) do
    add_palette_color(highlight.fg)
  end
  for _, color in ipairs({ 0x7aa2f7, 0x9ece6a, 0xe0af68, 0xbb9af7, 0x7dcfff, 0xff9e64 }) do
    add_palette_color(color)
  end
  welcome_palette = palette
  welcome_background = canvas
  local secondary = palette[4] or accent
  local input_bg = blend(foreground, canvas, 0.07)
  local code_bg = blend(0x000000, canvas, 0.16)
  local tool_bg = blend(foreground, canvas, 0.045)
  local widget_bg = blend(foreground, canvas, 0.055)
  local diff_add_bg = blend(success, canvas, 0.11)
  local diff_delete_bg = blend(error_color, canvas, 0.11)
  local cterm_foreground = normal.ctermfg or 15
  local cterm_background = normal.ctermbg or 0
  local cterm_muted = comment.ctermfg or 8
  local cterm_accent = info.ctermfg or 14
  local cterm_success = ok.ctermfg or 10
  local cterm_warning = warn.ctermfg or 11
  local cterm_error = err.ctermfg or 9
  local cterm_secondary = special.ctermfg or func.ctermfg or cterm_accent
  local cterm_plan = 13

  local groups = {
    PiCanvasNormal = { fg = foreground, bg = canvas },
    PiPanelTitle = { fg = accent, bold = true },
    PiPanelMuted = { fg = muted },
    PiPanelBorder = { fg = separator.fg or blend(foreground, canvas, 0.3), bg = canvas },
    PiWelcomeBorder = { fg = blend(accent, canvas, 0.68), bg = canvas },
    PiWelcomeTitle = { fg = warning, bg = canvas, bold = true },
    PiWelcomeAgent = { fg = success, bg = canvas, bold = true },
    PiWelcomeNeovim = { fg = secondary, bg = canvas, italic = true },
    PiWelcomeSection = { fg = warning, bg = canvas, bold = true },
    PiWelcomeLabel = { fg = muted, bg = canvas },
    PiWelcomeModelValue = { fg = accent, bg = canvas, bold = true },
    PiWelcomeThinkingValue = { fg = warning, bg = canvas, bold = true },
    PiWelcomeProjectValue = { fg = secondary, bg = canvas, bold = true },
    PiWelcomePermissionValue = { fg = warning, bg = canvas, bold = true },
    PiWelcomePermissionWarning = { fg = warning, bg = canvas, bold = true },
    PiWelcomePermissionSafe = { fg = success, bg = canvas, bold = true },
    PiWelcomePermissionDanger = { fg = error_color, bg = canvas, bold = true },
    PiInputBorder = { fg = accent, bg = input_bg },
    PiInputBorderMuted = { fg = blend(accent, canvas, 0.48), bg = input_bg },
    PiInputBorderTrail = { fg = blend(accent, canvas, 0.78), bg = input_bg },
    PiInputBorderPulse = { fg = blend(foreground, accent, 0.38), bg = input_bg, bold = true },
    PiInputBorderError = { fg = error_color, bg = input_bg, bold = true },
    PiInputCorner = { fg = accent, bg = input_bg },
    PiInputCornerMuted = { fg = blend(accent, canvas, 0.48), bg = input_bg },
    PiInputCornerError = { fg = error_color, bg = input_bg, bold = true },
    PiInputActivity = { fg = warning, bg = input_bg, bold = true },
    PiInputNormal = { fg = foreground, bg = input_bg },
    -- Terminals disagree on which cursor color is used for IME preedit text.
    -- Keep both channels black so the composition stays readable everywhere.
    PiInputCursor = { fg = 0x000000, bg = 0x000000, bold = true, nocombine = true },
    PiPermissionNormal = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
    },
    PiPermissionCursor = {
      fg = canvas,
      bg = canvas,
      ctermfg = cterm_background,
      ctermbg = cterm_background,
      nocombine = true,
    },
    PiPermissionVisual = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
    },
    PiPermissionEdge = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionRule = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
    },
    PiPermissionTitle = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionSubject = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionBody = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
    },
    PiPermissionPath = {
      fg = secondary,
      bg = canvas,
      ctermfg = cterm_secondary,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionCommand = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
    },
    PiPermissionCommandPrompt = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionQuestion = {
      fg = warning,
      bg = canvas,
      ctermfg = cterm_warning,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionChoice = {
      fg = foreground,
      bg = canvas,
      ctermfg = cterm_foreground,
      ctermbg = cterm_background,
    },
    PiPermissionBlock = {
      fg = muted,
      bg = canvas,
      ctermfg = cterm_muted,
      ctermbg = cterm_background,
    },
    PiPermissionAllow = {
      fg = muted,
      bg = canvas,
      ctermfg = cterm_muted,
      ctermbg = cterm_background,
    },
    PiPermissionSession = {
      fg = muted,
      bg = canvas,
      ctermfg = cterm_muted,
      ctermbg = cterm_background,
    },
    PiPermissionMarker = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionBlockSelected = {
      fg = error_color,
      ctermfg = cterm_error,
      bold = true,
    },
    PiPermissionAllowSelected = {
      fg = success,
      ctermfg = cterm_success,
      bold = true,
    },
    PiPermissionSessionSelected = {
      fg = accent,
      ctermfg = cterm_accent,
      bold = true,
    },
    PiPermissionShellCommand = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionShellOption = {
      fg = secondary,
      bg = canvas,
      ctermfg = cterm_secondary,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionShellOperator = {
      fg = muted,
      bg = canvas,
      ctermfg = cterm_muted,
      ctermbg = cterm_background,
      bold = true,
    },
    PiPermissionShellString = {
      fg = warning,
      bg = canvas,
      ctermfg = cterm_warning,
      ctermbg = cterm_background,
    },
    PiPermissionShellVariable = {
      fg = secondary,
      bg = canvas,
      ctermfg = cterm_secondary,
      ctermbg = cterm_background,
    },
    PiPermissionHint = {
      fg = muted,
      bg = canvas,
      ctermfg = cterm_muted,
      ctermbg = cterm_background,
    },
    PiPermissionSelected = {
      fg = foreground,
      ctermfg = cterm_foreground,
      bold = true,
    },
    PiCommandMenu = { fg = muted, bg = canvas },
    PiCommandSelected = { bg = blend(accent, canvas, 0.075) },
    PiCommandMarker = { fg = accent, bold = true },
    PiCommandName = { fg = foreground },
    PiCommandNameSelected = { fg = accent, bold = true },
    PiCommandMatch = { fg = warning, bold = true },
    PiCommandHint = { fg = muted, italic = true },
    PiCommandDescription = { fg = muted },
    PiCommandDescriptionSelected = { fg = foreground },
    PiInlineMenu = { fg = foreground, bg = canvas },
    PiInlineTitle = { fg = accent, bg = canvas, bold = true },
    PiInlineQuery = { fg = muted, bg = canvas, bold = true },
    PiInlineInput = { fg = warning, bg = canvas },
    PiInlineSelected = { bg = blend(accent, canvas, 0.075) },
    PiInlineMarker = { fg = accent, bg = canvas, bold = true },
    PiInlineItem = { fg = foreground, bg = canvas },
    PiInlineCurrent = { fg = success, bg = canvas, bold = true },
    PiInlineDescription = { fg = muted, bg = canvas },
    PiInlineError = { fg = error_color, bg = canvas, bold = true },
    PiInlineLoading = { fg = warning, bg = canvas, italic = true },
    PiUserLabel = { fg = accent, bg = blend(accent, canvas, 0.14), bold = true },
    PiUserMessageText = { fg = foreground, bg = blend(accent, canvas, 0.14) },
    PiUserMessageBg = { bg = blend(accent, canvas, 0.14) },
    PiUserAttachment = { fg = success, bg = blend(accent, canvas, 0.14), bold = true },
    PiImageSurface = { fg = foreground, bg = canvas },
    PiImageFallback = { fg = muted, bg = canvas, italic = true },
    PiInputAttachment = { fg = success, bg = input_bg, bold = true },
    PiInputAttachmentSelected = { fg = success, bg = input_bg, bold = true, reverse = true },
    PiWidgetNormal = { fg = foreground, bg = widget_bg },
    PiWidgetTitle = { fg = accent, bg = widget_bg, bold = true },
    PiWidgetText = { fg = foreground, bg = widget_bg },
    PiWidgetActive = { fg = warning, bg = widget_bg, bold = true },
    PiWidgetPending = { fg = foreground, bg = widget_bg },
    PiWidgetCompleted = { fg = success, bg = widget_bg },
    PiWidgetMuted = { fg = muted, bg = widget_bg, italic = true },
    PiPlanMarker = { fg = muted },
    PiPlanTitle = { fg = foreground, bold = true },
    PiPlanText = { fg = foreground },
    PiPlanActive = { fg = warning, bold = true },
    PiPlanPending = { fg = foreground },
    PiPlanCompleted = { fg = success },
    PiPlanMuted = { fg = muted, italic = true },
    PiAssistantLabel = { fg = success, bold = true },
    PiProcessSummary = { fg = muted, italic = true },
    PiProcessToggle = { fg = accent, bold = true },
    PiToolGroupLabel = { fg = accent, bold = true },
    PiToolRunning = { fg = warning, bold = true },
    PiToolSuccess = { fg = success, bold = true },
    PiToolFailed = { fg = error_color, bold = true },
    PiToolVerb = { fg = accent, bold = true },
    PiToolCommand = { fg = foreground },
    PiToolSubject = { fg = accent },
    PiToolGutter = { fg = muted },
    PiToolSurface = { bg = tool_bg },
    PiToolOutput = { fg = foreground, bg = tool_bg },
    PiToolOmitted = { fg = muted, bg = tool_bg, italic = true },
    PiToolError = { fg = error_color, bold = true },
    PiDiffAdd = { fg = success, bg = diff_add_bg, bold = true },
    PiDiffDelete = { fg = error_color, bg = diff_delete_bg },
    PiDiffAddLine = { bg = diff_add_bg },
    PiDiffDeleteLine = { bg = diff_delete_bg },
    PiCodeBg = { bg = code_bg },
    PiCodeLineNumber = { fg = muted, bg = code_bg },
    PiMarkdownCode = { fg = foreground, bg = code_bg },
    PiMarkdownHeading = { fg = accent, bold = true },
    PiMarkdownQuote = { fg = muted, italic = true },
    PiMarkdownStrong = { fg = foreground, bold = true },
    PiMarkdownEmphasis = { fg = foreground, italic = true },
    PiMarkdownInlineCode = { fg = warning, bg = code_bg },
    PiMarkdownLink = { fg = accent, underline = true },
    PiMarkdownListMarker = { fg = warning, bold = true },
    PiThinkingLabel = { fg = warning, bold = true },
    PiThinkingText = { fg = blend(warning, canvas, 0.72), italic = true },
    PiHeaderHint = { fg = muted },
    PiStatusNormal = { fg = foreground, bg = canvas },
    PiStatusContext = { fg = muted, bg = canvas },
    PiStatusModel = { fg = accent, bg = canvas, bold = true },
    PiStatusThinking = { fg = warning, bg = canvas, bold = true },
    PiStatusPermission = { fg = accent, bg = canvas, bold = true },
    PiStatusPermissionManual = {
      fg = warning,
      bg = canvas,
      ctermfg = cterm_warning,
      ctermbg = cterm_background,
      bold = true,
    },
    PiStatusPermissionAcceptEdits = {
      fg = success,
      bg = canvas,
      ctermfg = cterm_success,
      ctermbg = cterm_background,
      bold = true,
    },
    PiStatusPermissionAuto = {
      fg = accent,
      bg = canvas,
      ctermfg = cterm_accent,
      ctermbg = cterm_background,
      bold = true,
    },
    PiStatusPermissionPlan = {
      fg = secondary,
      bg = canvas,
      ctermfg = cterm_plan,
      ctermbg = cterm_background,
      bold = true,
    },
    PiStatusWorking = { fg = warning, bg = canvas, bold = true },
    PiStatusWarning = { fg = warning, bg = canvas, bold = true },
    PiStatusError = { fg = error_color, bg = canvas, bold = true },
  }
  for name, attributes in pairs(groups) do
    vim.api.nvim_set_hl(0, name, attributes)
  end
end

function M.setup()
  setup()
end

function M.welcome_palette()
  return welcome_palette, welcome_background
end

return M
