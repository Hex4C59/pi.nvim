local M = {}

function M.text_content(content)
  if type(content) == "string" then
    return content
  end

  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      table.insert(parts, block.text or "")
    end
  end
  return table.concat(parts, "\n")
end

return M
