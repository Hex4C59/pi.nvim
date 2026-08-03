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

return M
