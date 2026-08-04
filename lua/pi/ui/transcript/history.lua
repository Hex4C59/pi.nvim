local text_content = require("pi.message").text_content

local M = {}

function M.events(messages)
  local events = {}
  for _, message in ipairs(messages or {}) do
    if type(message) == "table" and message.role == "user" then
      table.insert(events, {
        kind = "user",
        message = message,
        text = text_content(message.content),
        content = message.content,
      })
    elseif type(message) == "table" and message.role == "assistant" then
      table.insert(events, { kind = "assistant", message = message })
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "toolCall" then
          table.insert(events, { kind = "tool_call", block = block })
        end
      end
    elseif type(message) == "table" and message.role == "toolResult" then
      table.insert(events, { kind = "tool_result", message = message })
    elseif type(message) == "table" and message.role == "bashExecution" then
      table.insert(events, { kind = "bash", message = message })
    elseif
      type(message) == "table"
      and (message.role == "compactionSummary" or message.role == "branchSummary")
      and type(message.summary) == "string"
    then
      table.insert(events, { kind = "summary", message = message })
    elseif type(message) == "table" and message.role == "custom" and message.display == true then
      table.insert(events, {
        kind = "custom",
        message = message,
        text = text_content(message.content),
      })
    end
  end
  return events
end

function M.replay(messages, handlers)
  for _, event in ipairs(M.events(messages)) do
    local handler = handlers[event.kind]
    if handler then
      handler(event)
    end
  end
end

return M
