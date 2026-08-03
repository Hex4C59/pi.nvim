local M = {}

function M.total_bytes(parts)
  parts = parts or {}
  return math.max(0, tonumber(parts.non_tool) or 0)
    + math.max(0, tonumber(parts.tool) or 0)
    + math.max(0, tonumber(parts.projection) or 0)
    + #(parts.reasoning_buffer or "")
    + #(parts.reasoning_header or "")
end

local function append_tool_actions(actions, item)
  table.insert(actions, { kind = "tool_output", item = item })
  table.insert(actions, { kind = "tool_args", item = item })
  table.insert(actions, { kind = "tool_args_full", item = item })
end

function M.candidates(items, streaming_assistant)
  local actions = {}
  for _, item in ipairs(items or {}) do
    if item.type == "tool" and item.state == "done" then
      append_tool_actions(actions, item)
    elseif item.type ~= "tool" and (item.type ~= "assistant" or item ~= streaming_assistant) then
      table.insert(actions, { kind = "body", item = item })
    end
  end
  for _, item in ipairs(items or {}) do
    if item.type == "tool" then
      append_tool_actions(actions, item)
    else
      table.insert(actions, { kind = "body", item = item })
    end
  end
  return actions
end

return M
