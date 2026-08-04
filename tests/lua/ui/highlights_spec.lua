local highlights = require("pi.ui.highlights")

local source_groups = {
  "Normal",
  "Comment",
  "DiagnosticInfo",
  "DiagnosticOk",
  "DiagnosticWarn",
  "DiagnosticError",
  "DiagnosticHint",
  "Special",
  "Function",
  "String",
  "WinSeparator",
}
local original_background = vim.o.background
local originals = {}
for _, name in ipairs(source_groups) do
  originals[name] = vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function channel(color, shift)
  return math.floor(color / (2 ^ shift)) % 256 / 255
end

local function luminance(color)
  local function linear(value)
    return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(channel(color, 16)) + 0.7152 * linear(channel(color, 8)) + 0.0722 * linear(channel(color, 0))
end

local function contrast(left, right)
  local bright = math.max(luminance(left), luminance(right))
  local dark = math.min(luminance(left), luminance(right))
  return (bright + 0.05) / (dark + 0.05)
end

local function clear_sources(normal)
  for _, name in ipairs(source_groups) do
    vim.api.nvim_set_hl(0, name, {})
  end
  vim.api.nvim_set_hl(0, "Normal", normal or {})
end

local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function run_case(case)
  vim.o.background = case.background
  clear_sources(case.opaque and { bg = case.reference } or {})
  highlights.setup()

  assert(hl("PiCanvasNormal").fg == case.foreground, case.label .. " foreground fallback changed")
  assert(hl("PiPanelTitle").fg == case.accent, case.label .. " accent fallback changed")
  assert(hl("PiToolSuccess").fg == case.success, case.label .. " success fallback changed")
  assert(hl("PiThinkingLabel").fg == case.warning, case.label .. " warning fallback changed")
  assert(hl("PiToolFailed").fg == case.error, case.label .. " error fallback changed")
  assert(
    contrast(hl("PiCanvasNormal").fg, case.reference) >= 4.5,
    case.label .. " body text does not meet 4.5:1 contrast"
  )

  for _, name in ipairs({
    "PiCanvasNormal",
    "PiWelcomeTitle",
    "PiStatusNormal",
    "PiPermissionNormal",
    "PiInlineMenu",
  }) do
    local background = hl(name).bg
    assert(
      (case.opaque and background ~= nil) or (not case.opaque and background == nil),
      case.label .. " canvas background policy changed for " .. name
    )
  end

  for _, name in ipairs({
    "PiInputNormal",
    "PiUserMessageBg",
    "PiToolSurface",
    "PiCodeBg",
    "PiDiffAddLine",
    "PiDiffDeleteLine",
    "PiWidgetNormal",
    "PiInlineSelected",
  }) do
    assert(hl(name).bg ~= nil, case.label .. " lost semantic surface background for " .. name)
  end

  local _, welcome_background = highlights.welcome_palette()
  assert(
    (case.opaque and welcome_background ~= nil) or (not case.opaque and welcome_background == nil),
    case.label .. " welcome animation background policy changed"
  )
end

local cases = {
  {
    label = "dark opaque",
    background = "dark",
    opaque = true,
    reference = 0x1e1e1e,
    foreground = 0xd4d4d4,
    accent = 0x7aa2f7,
    success = 0x9ece6a,
    warning = 0xe0af68,
    error = 0xf7768e,
  },
  {
    label = "dark transparent",
    background = "dark",
    opaque = false,
    reference = 0x1e1e1e,
    foreground = 0xd4d4d4,
    accent = 0x7aa2f7,
    success = 0x9ece6a,
    warning = 0xe0af68,
    error = 0xf7768e,
  },
  {
    label = "light opaque",
    background = "light",
    opaque = true,
    reference = 0xf5f5f5,
    foreground = 0x202020,
    accent = 0x005f87,
    success = 0x2e7d32,
    warning = 0x7a4b00,
    error = 0xb42318,
  },
  {
    label = "light transparent",
    background = "light",
    opaque = false,
    reference = 0xf5f5f5,
    foreground = 0x202020,
    accent = 0x005f87,
    success = 0x2e7d32,
    warning = 0x7a4b00,
    error = 0xb42318,
  },
}

local ok, err = xpcall(function()
  for _, case in ipairs(cases) do
    run_case(case)
  end
  vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x123456 })
  vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x246824 })
  highlights.setup()
  assert(hl("PiPanelTitle").fg == 0x123456, "colorscheme accent did not override the fallback")
  assert(hl("PiToolSuccess").fg == 0x246824, "colorscheme success did not override the fallback")
end, debug.traceback)

vim.o.background = original_background
for _, name in ipairs(source_groups) do
  vim.api.nvim_set_hl(0, name, originals[name])
end
highlights.setup()
if not ok then
  error(err)
end

print("highlights_spec: ok")
