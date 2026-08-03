local M = {}

function M.split_lines(value)
  if not value or value == "" then
    return {}
  end
  local normalized = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(normalized, "\n", { plain = true })
end

function M.single_line(value)
  return (tostring(value or ""):gsub("[\r\n]+", " ↵ "))
end

function M.result_text(result)
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

function M.format_duration(milliseconds)
  if not milliseconds then
    return nil
  elseif milliseconds < 1000 then
    return ("%dms"):format(milliseconds)
  elseif milliseconds < 60000 then
    return ("%.1fs"):format(milliseconds / 1000)
  end
  return format_hms(milliseconds / 1000)
end

function M.format_bytes(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  if bytes >= 1024 * 1024 then
    return ("%.1f MiB"):format(bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return ("%.1f KiB"):format(bytes / 1024)
  end
  return ("%d bytes"):format(bytes)
end

function M.format_elapsed(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if seconds < 10 then
    return ("%.1fs"):format(seconds)
  end
  return format_hms(math.floor(seconds + 0.5))
end

function M.truncate_display(value, width)
  local text = M.single_line(value)
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

return M
