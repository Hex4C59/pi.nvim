local M = {}

function M.compact_count(value)
  value = tonumber(value) or 0
  if value < 1000 then
    return tostring(math.floor(value))
  elseif value < 10000 then
    return ("%.1fk"):format(value / 1000)
  elseif value < 1000000 then
    return ("%dk"):format(math.floor(value / 1000 + 0.5))
  elseif value < 10000000 then
    return ("%.1fM"):format(value / 1000000)
  end
  return ("%dM"):format(math.floor(value / 1000000 + 0.5))
end

return M
