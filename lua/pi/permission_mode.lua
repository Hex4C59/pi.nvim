local M = {}

M.order = { "manual", "acceptEdits", "auto", "plan" }

local descriptions = {
  manual = "Allow workspace reads; ask before Bash, file changes, and outside reads",
  acceptEdits = "Allow workspace edits/writes; ask before Bash and outside access",
  auto = "Allow validated built-in tool calls without confirmation",
  plan = "Expose read/grep/find/ls/todo only; make no project changes",
}

local labels = {
  manual = "Manual",
  acceptEdits = "Accept edits",
  auto = "Auto",
  plan = "Plan",
}

local aliases = {
  manual = "manual",
  default = "manual",
  confirm = "manual",
  confirmchanges = "manual",
  acceptedits = "acceptEdits",
  ["accept-edits"] = "acceptEdits",
  ["accept_edits"] = "acceptEdits",
  auto = "auto",
  plan = "plan",
}

local function normalized_key(value)
  value = vim.trim(tostring(value or ""))
  return value:lower():gsub("[%s_%-]", "")
end

function M.normalize(value)
  return aliases[normalized_key(value)]
end

function M.label(mode)
  if mode == nil then
    return "--"
  end
  return labels[M.normalize(mode) or mode] or tostring(mode)
end

function M.description(mode)
  return descriptions[M.normalize(mode) or mode] or ""
end

function M.default_for_security(security_mode)
  if security_mode == "read-only" then
    return "plan"
  elseif security_mode == "full" then
    return "auto"
  end
  return "manual"
end

function M.options()
  local result = {}
  for _, mode in ipairs(M.order) do
    table.insert(result, {
      value = mode,
      label = labels[mode],
      description = descriptions[mode],
    })
  end
  return result
end

function M.cycle(mode, delta)
  local current = M.normalize(mode) or M.order[1]
  local index = 1
  for position, candidate in ipairs(M.order) do
    if candidate == current then
      index = position
      break
    end
  end
  delta = delta or 1
  return M.order[(index - 1 + delta) % #M.order + 1]
end

return M
