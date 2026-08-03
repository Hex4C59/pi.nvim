local root = vim.fs.joinpath(vim.fn.getcwd(), "runtime-project")
local created_chats = {}

local FakeChat = {}
FakeChat.__index = FakeChat

function FakeChat.new(chat_root)
  local chat = setmetatable({
    root = chat_root,
    reset_count = 0,
    histories = {},
    stats = {},
    states = {},
    commands = {},
    users = {},
    restored_images = {},
    started_tools = {},
    ended_tools = {},
    ended_bash = {},
    open_count = 0,
    destroy_count = 0,
  }, FakeChat)
  table.insert(created_chats, chat)
  return chat
end

function FakeChat:owns_buffer()
  return false
end

function FakeChat:reset_session_projection()
  self.reset_count = self.reset_count + 1
end

function FakeChat:update_state(state)
  table.insert(self.states, state)
end

function FakeChat:update_stats(stats)
  table.insert(self.stats, stats)
end

function FakeChat:render_history(messages)
  table.insert(self.histories, messages)
end

function FakeChat:set_commands(commands)
  self.commands = commands
end

function FakeChat:add_user(text, content)
  table.insert(self.users, { text = text, content = content })
end

function FakeChat:validate_image_attachments()
  return true
end

function FakeChat:restore_image_attachments(images)
  table.insert(self.restored_images, images)
  return true
end

function FakeChat:localize_images(images)
  return images
end

function FakeChat:open()
  self.open_count = self.open_count + 1
end

function FakeChat:start_tool(id, name, args)
  table.insert(self.started_tools, { id = id, name = name, args = args })
end

function FakeChat:end_tool(id, result, is_error)
  table.insert(self.ended_tools, { id = id, result = result, is_error = is_error })
end

function FakeChat:end_bash(id, data, is_error)
  table.insert(self.ended_bash, { id = id, data = data, is_error = is_error })
end

function FakeChat:destroy()
  self.destroy_count = self.destroy_count + 1
end

local clients = {}

local function make_client(label, client_root)
  local client = {
    label = label,
    root = client_root,
    state = "idle",
    session = {},
    requests = {},
    listeners = {},
    stop_count = 0,
    unsubscribe_count = 0,
  }

  function client:on_event(listener)
    table.insert(self.listeners, listener)
    self.last_listener = listener
    local subscribed = true
    return function()
      if not subscribed then
        return false
      end
      subscribed = false
      self.unsubscribe_count = self.unsubscribe_count + 1
      for index, candidate in ipairs(self.listeners) do
        if candidate == listener then
          table.remove(self.listeners, index)
          break
        end
      end
      return true
    end
  end

  function client:start()
    return true
  end

  function client:stop()
    self.stop_count = self.stop_count + 1
  end

  function client:request(command, payload, callback, timeout)
    local entry = {
      id = ("%s-%d"):format(self.label, #self.requests + 1),
      command = command,
      payload = payload,
      callback = callback,
      timeout = timeout,
    }
    table.insert(self.requests, entry)
    return entry.id
  end

  function client:emit(event)
    for _, listener in ipairs(vim.list_slice(self.listeners)) do
      listener(event)
    end
  end

  table.insert(clients, client)
  return client
end

local function requests_for(client, command)
  local matches = {}
  for _, request in ipairs(client.requests) do
    if request.command == command then
      table.insert(matches, request)
    end
  end
  return matches
end

local function latest_request(client, command)
  local matches = requests_for(client, command)
  return assert(matches[#matches], "missing " .. command .. " request")
end

local function respond(request, success, data, err)
  assert(not request.responded, "request callback was invoked twice")
  request.responded = true
  if request.callback then
    request.callback(success, data, err)
  end
end

local generation = 0
package.loaded["pi.ui.chat"] = { Chat = FakeChat }
package.loaded["pi.ui.dialog"] = {
  handle = function() end,
  discard = function() end,
}
package.loaded["pi.client"] = {
  Client = {
    new = function(client_root)
      generation = generation + 1
      return make_client("client" .. generation, client_root)
    end,
  },
}
package.loaded["pi.runtime"] = nil
local runtime = require("pi.runtime")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local client = runtime.get_client(root)
local chat = runtime.chat_for(root)
runtime.reload_session(client)
assert(chat.reset_count == 1, "session reload bypassed the Chat projection facade")
assert(#requests_for(client, "get_state") == 1, "session reload did not refresh state exactly once")
assert(#requests_for(client, "get_session_stats") == 1, "session reload did not refresh stats exactly once")
assert(#requests_for(client, "get_messages") == 1, "session reload did not request history exactly once")

runtime.refresh_stats(client)
runtime.refresh_stats(client)
assert(#requests_for(client, "get_session_stats") == 1, "concurrent stats refreshes were not de-duplicated")
respond(latest_request(client, "get_state"), true, { model = { id = "fixture" } })
respond(latest_request(client, "get_session_stats"), true, { cost = 1 })
respond(latest_request(client, "get_messages"), true, { messages = { { role = "user", content = {} } } })
assert(client.session.model.id == "fixture", "session reload did not update the declared Client session mirror")
assert(#chat.stats == 1 and chat.stats[1].cost == 1, "stats refresh did not reach Chat")
assert(#chat.histories == 1, "session history did not reach Chat")

runtime.refresh_stats(client)
runtime.refresh_stats(client)
assert(#requests_for(client, "get_session_stats") == 2, "settled stats refresh did not admit one new request")
respond(latest_request(client, "get_session_stats"), false, nil, "stats unavailable")
runtime.refresh_stats(client)
assert(#requests_for(client, "get_session_stats") == 3, "failed stats refresh left the de-duplication flag stuck")
respond(latest_request(client, "get_session_stats"), true, { cost = 2 })

runtime.refresh_commands(client)
respond(latest_request(client, "get_commands"), true, {
  commands = {
    { name = "builtin", source = "builtin" },
    { name = "extension", source = "extension" },
  },
})
assert(#chat.commands == 2, "discovered commands did not reach Chat")

runtime.send_prompt("/builtin", nil, root)
local builtin_prompt = latest_request(client, "prompt")
respond(builtin_prompt, true, {})
client:emit({
  type = "message_start",
  message = { role = "user", content = { { type = "text", text = "expanded builtin" } } },
})
assert(chat.users[#chat.users].text == "/builtin", "builtin command display correlation was lost")

runtime.send_prompt("/extension", nil, root)
local extension_prompt = latest_request(client, "prompt")
respond(extension_prompt, true, {})
client:emit({
  type = "message_start",
  message = { role = "user", content = { { type = "text", text = "expanded extension" } } },
})
assert(chat.users[#chat.users].text == "expanded extension", "Extension output was replaced by a local command display")

runtime.send_prompt("accepted", "accepted display", root)
local accepted_prompt = latest_request(client, "prompt")
local image = { type = "image", mimeType = "image/png", data = "fixture" }
runtime.send_prompt("rejected", "rejected display", root, nil, { image })
local rejected_prompt = latest_request(client, "prompt")
respond(rejected_prompt, false, nil, "fixture rejection")
assert(#chat.restored_images == 1 and chat.restored_images[1][1] == image, "failed prompt did not restore images")
assert(notifications[#notifications].message == "fixture rejection", "failed prompt did not report its RPC error")
client:emit({
  type = "message_start",
  message = { role = "user", content = { { type = "text", text = "wire display" } } },
})
assert(chat.users[#chat.users].text == "accepted display", "a failed prompt displaced an earlier display entry")
respond(accepted_prompt, true, {})

runtime.run_bash("first", root)
local first_bash = latest_request(client, "bash")
runtime.run_bash("second", root)
local second_bash = latest_request(client, "bash")
respond(first_bash, true, { output = "first", exitCode = 0 })
runtime.abort(root)
local abort_bash = latest_request(client, "abort_bash")
respond(abort_bash, true, {})
assert(abort_bash.payload and next(abort_bash.payload) == nil, "direct Bash abort payload changed")
respond(second_bash, true, { output = "second", exitCode = 0 })
runtime.abort(root)
local abort_agent = latest_request(client, "abort")
assert(abort_agent.payload and next(abort_agent.payload) == nil, "agent abort payload changed")
assert(#chat.started_tools == 2 and #chat.ended_bash == 2, "direct Bash lifecycle did not reach Chat")

for _, field in ipairs({ "commands_by_name", "stats_pending", "display_queue", "runtime_unsubscribe", "bash_running" }) do
  assert(client[field] == nil, "Runtime dynamically attached Client field " .. field)
end

runtime.send_prompt("late prompt", "late display", root)
local late_prompt = latest_request(client, "prompt")
runtime.run_bash("late bash", root)
local late_bash = latest_request(client, "bash")
local late_listener = client.last_listener
local notification_count = #notifications
runtime.stop(root)
assert(client.stop_count == 1 and client.unsubscribe_count == 1, "Runtime did not stop and unsubscribe the old Client")
assert(chat.destroy_count == 1, "Runtime did not destroy the old Chat")

local replacement = runtime.get_client(root)
local replacement_chat = runtime.chat_for(root)
late_listener({
  type = "message_start",
  message = { role = "user", content = { { type = "text", text = "late event" } } },
})
respond(late_prompt, false, nil, "late failure")
respond(late_bash, true, { output = "late", exitCode = 0 })
assert(#replacement_chat.users == 0, "a replaced Client projected a late event into the new Chat")
assert(#replacement_chat.ended_bash == 0, "a replaced Client completed Bash in the new Chat")
assert(#notifications == notification_count, "a replaced Client surfaced a stale callback error")
runtime.abort(root)
assert(latest_request(replacement, "abort").command == "abort", "replacement inherited the old direct Bash request")

for _, field in ipairs({ "commands_by_name", "stats_pending", "display_queue", "runtime_unsubscribe", "bash_running" }) do
  assert(replacement[field] == nil, "replacement Client received Runtime field " .. field)
end

runtime.stop(root)
vim.notify = original_notify
print("runtime_spec: ok")
