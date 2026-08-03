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
  local diff_add_bg = blend(success, canvas, 0.11)
  local diff_delete_bg = blend(error_color, canvas, 0.11)

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
    PiWelcomePermissionSafe = { fg = success, bg = canvas, bold = true },
    PiWelcomePermissionDanger = { fg = error_color, bg = canvas, bold = true },
    PiInputBorder = { fg = accent, bg = input_bg },
    PiInputBorderMuted = { fg = blend(accent, canvas, 0.48), bg = input_bg },
    PiInputBorderTrail = { fg = blend(accent, canvas, 0.78), bg = input_bg },
    PiInputBorderPulse = { fg = blend(foreground, accent, 0.38), bg = input_bg, bold = true },
    PiInputBorderError = { fg = error_color, bg = input_bg, bold = true },
    PiInputCorner = { fg = accent, bg = canvas },
    PiInputCornerMuted = { fg = blend(accent, canvas, 0.48), bg = canvas },
    PiInputCornerError = { fg = error_color, bg = canvas, bold = true },
    PiInputActivity = { fg = warning, bg = input_bg, bold = true },
    PiInputNormal = { fg = foreground, bg = input_bg, bold = true },
    -- Kitty reverses the cursor SGR when drawing IME preedit text, so this
    -- background becomes the preedit foreground.
    PiInputCursor = { fg = foreground, bg = 0x000000, bold = true, nocombine = true },
    PiCommandMenu = { fg = muted, bg = canvas },
    PiCommandSelected = { bg = blend(accent, canvas, 0.075) },
    PiCommandMarker = { fg = accent, bold = true },
    PiCommandName = { fg = foreground },
    PiCommandNameSelected = { fg = accent, bold = true },
    PiCommandMatch = { fg = warning, bold = true },
    PiCommandHint = { fg = muted, italic = true },
    PiCommandDescription = { fg = muted },
    PiCommandDescriptionSelected = { fg = foreground },
    PiUserLabel = { fg = accent, bg = blend(accent, canvas, 0.14), bold = true },
    PiUserMessageText = { fg = foreground, bg = blend(accent, canvas, 0.14) },
    PiUserMessageBg = { bg = blend(accent, canvas, 0.14) },
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
