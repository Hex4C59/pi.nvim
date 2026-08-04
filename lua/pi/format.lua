local M = {}

local function one_decimal(value, divisor, suffix)
  local scaled = value * 10 / divisor
  local lower = math.floor(scaled)
  local fraction = scaled - lower
  if fraction > 0.5 or (fraction == 0.5 and lower % 2 == 1) then
    lower = lower + 1
  end
  return ("%d.%d%s"):format(math.floor(lower / 10), lower % 10, suffix)
end

function M.compact_count(value)
  value = tonumber(value) or 0
  if value < 1000 then
    return tostring(math.floor(value))
  elseif value < 10000 then
    return one_decimal(value, 1000, "k")
  elseif value < 1000000 then
    return ("%dk"):format(math.floor(value / 1000 + 0.5))
  elseif value < 10000000 then
    return one_decimal(value, 1000000, "M")
  end
  return ("%dM"):format(math.floor(value / 1000000 + 0.5))
end

local function display_prefix(value, width)
  local result = ""
  local last_safe = ""
  for index = 0, vim.fn.strchars(value) - 1 do
    local character = vim.fn.strcharpart(value, index, 1)
    local candidate = result .. character
    if vim.fn.strdisplaywidth(candidate) > width then
      break
    end
    result = candidate
    if vim.fn.char2nr(character) ~= 0x200D then
      last_safe = result
    end
  end
  return result == last_safe and result or last_safe
end

function M.truncate_display(value, width, suffix)
  local text = tostring(value or "")
  width = math.max(0, math.floor(tonumber(width) or 0))
  suffix = tostring(suffix or "...")
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(suffix) > width then
    return display_prefix(suffix, width)
  end
  local prefix = display_prefix(text, width - vim.fn.strdisplaywidth(suffix))
  return prefix .. suffix
end

return M
