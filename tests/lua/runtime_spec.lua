local root = vim.fs.joinpath(vim.fn.getcwd(), "runtime-project")
local pagination_root = root .. "-paginated"
local created_chats = {}

local FakeChat = {}
FakeChat.__index = FakeChat

function FakeChat.new(chat_root)
  local chat = setmetatable({
    root = chat_root,
    reset_count = 0,
    histories = {},
    history_pages = {},
    history_states = {},
    stats = {},
    states = {},
    commands = {},
    users = {},
    restored_images = {},
    started_tools = {},
    ended_tools = {},
    ended_bash = {},
    activities = {},
    status_items = {},
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

function FakeChat:render_history_page(items, prepend)
  table.insert(self.history_pages, { items = items, prepend = prepend })
end

function FakeChat:set_history_state(state, detail)
  table.insert(self.history_states, { state = state, detail = detail })
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

function FakeChat:set_activity(activity)
  table.insert(self.activities, activity)
end

function FakeChat:add_status(message, is_error)
  table.insert(self.status_items, { message = message, is_error = is_error })
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

local previous_modules = {
  chat = package.loaded["pi.ui.chat"],
  dialog = package.loaded["pi.ui.dialog"],
  client = package.loaded["pi.client"],
  runtime = package.loaded["pi.runtime"],
}
local original_notify = vim.notify
local runtime

local function run()
  local generation = 0
  local dialog_cancellations = {}
  local dialog_discards = 0
  package.loaded["pi.ui.chat"] = { Chat = FakeChat }
  package.loaded["pi.ui.dialog"] = {
    handle = function() end,
    cancel = function(client, id)
      table.insert(dialog_cancellations, { client = client, id = id })
    end,
    discard = function()
      dialog_discards = dialog_discards + 1
    end,
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
  runtime = require("pi.runtime")

  local notifications = {}
  vim.notify = function(message, level)
    table.insert(notifications, { message = message, level = level })
  end

  local client = runtime.get_client(root)
  local chat = runtime.chat_for(root)
  local first_action = runtime.begin_session_action(client)
  assert(runtime.session_action_current(client, first_action), "new session action was not current")
  local second_action = runtime.begin_session_action(client)
  assert(
    not runtime.session_action_current(client, first_action),
    "new session action did not invalidate the old action"
  )
  assert(runtime.session_action_current(client, second_action), "latest session action was not current")
  runtime.reload_session(client)
  assert(
    not runtime.session_action_current(client, second_action),
    "session reload did not invalidate pending session actions"
  )
  assert(dialog_discards == 1, "session reload did not discard dialogs from the previous session")
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

  client:emit({ type = "extension_ui_cancel", id = "server-cancelled" })
  assert(
    #dialog_cancellations == 1
      and dialog_cancellations[1].client == client
      and dialog_cancellations[1].id == "server-cancelled",
    "runtime did not route the authoritative Extension UI cancellation"
  )

  runtime.refresh_stats(client)
  runtime.refresh_stats(client)
  assert(#requests_for(client, "get_session_stats") == 2, "settled stats refresh did not admit one new request")
  respond(latest_request(client, "get_session_stats"), false, nil, "stats unavailable")
  runtime.refresh_stats(client)
  assert(#requests_for(client, "get_session_stats") == 3, "failed stats refresh left the de-duplication flag stuck")
  respond(latest_request(client, "get_session_stats"), true, { cost = 2 })

  client:emit({ type = "auto_retry_start", attempt = 2, maxAttempts = 3 })
  assert(chat.activities[#chat.activities] == "retry 2/3", "retry start did not project its attempt")
  client:emit({ type = "auto_retry_end", success = false, finalError = "retry exhausted" })
  assert(chat.activities[#chat.activities] == "retry 2/3", "retry end became idle before agent_settled")
  assert(
    chat.status_items[#chat.status_items].message == "retry exhausted"
      and chat.status_items[#chat.status_items].is_error == true,
    "failed retry did not project its final error"
  )
  runtime.abort(root)
  assert(latest_request(client, "abort").command == "abort", "retry interruption did not send abort")
  respond(latest_request(client, "abort"), true, {})
  client:emit({ type = "agent_settled" })
  assert(chat.activities[#chat.activities] == "idle", "agent_settled did not end retry activity")
  respond(latest_request(client, "get_session_stats"), true, { cost = 3 })

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
  assert(
    chat.users[#chat.users].text == "expanded extension",
    "Extension output was replaced by a local command display"
  )

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
  assert(
    client.stop_count == 1 and client.unsubscribe_count == 1,
    "Runtime did not stop and unsubscribe the old Client"
  )
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

  local paginated = runtime.get_client(pagination_root)
  local paginated_chat = runtime.chat_for(pagination_root)
  paginated:emit({
    type = "client_state",
    data = {
      sessionId = "session-a",
      rpcCapabilities = { "history_pagination" },
    },
  })
  local first_page = latest_request(paginated, "get_messages_page")
  assert(
    first_page.payload.cursor == nil and first_page.payload.limit == 50 and first_page.payload.maxBytes == 1024 * 1024,
    "initial history page did not use the bounded pagination contract"
  )
  assert(#requests_for(paginated, "get_messages") == 0, "capable Pi process received the legacy history request")
  respond(first_page, true, {
    items = { { entryId = "entry-new", messages = { { role = "user", content = {} } } } },
    nextCursor = "cursor-a",
    hasMore = true,
    leafId = "leaf-a",
  })
  assert(
    #paginated_chat.history_pages == 1
      and paginated_chat.history_pages[1].prepend == false
      and paginated_chat.history_states[#paginated_chat.history_states].state == "more",
    "newest history page did not initialize the paginated projection"
  )

  assert(runtime.load_older_history(pagination_root), "older history action did not start a page request")
  local stale_page = latest_request(paginated, "get_messages_page")
  assert(stale_page.payload.cursor == "cursor-a", "older history request lost its opaque cursor")
  runtime.reload_session(paginated)
  local restarted_page = latest_request(paginated, "get_messages_page")
  assert(
    restarted_page ~= stale_page and restarted_page.payload.cursor == nil,
    "session reload did not restart history"
  )
  respond(stale_page, true, {
    items = { { entryId = "entry-stale", messages = {} } },
    nextCursor = nil,
    hasMore = false,
    leafId = "leaf-a",
  })
  assert(#paginated_chat.history_pages == 1, "stale page response crossed the session generation boundary")
  respond(restarted_page, true, {
    items = { { entryId = "entry-new", messages = { { role = "assistant", content = {} } } } },
    nextCursor = "cursor-b",
    hasMore = true,
    leafId = "leaf-b",
  })
  assert(
    #paginated_chat.history_pages == 2 and paginated_chat.history_pages[2].prepend == false,
    "restarted history did not replace the previous projection"
  )

  assert(runtime.load_older_history(pagination_root), "older page error fixture did not start")
  local failed_page = latest_request(paginated, "get_messages_page")
  respond(failed_page, false, nil, "temporary history failure")
  local failed_state = paginated_chat.history_states[#paginated_chat.history_states]
  assert(
    failed_state.state == "error" and failed_state.detail == "temporary history failure",
    "history page failure was not exposed as retryable structured state"
  )
  assert(runtime.load_older_history(pagination_root), "failed history page could not be retried")
  local retry_page = latest_request(paginated, "get_messages_page")
  assert(retry_page.payload.cursor == "cursor-b", "history retry changed its continuation cursor")
  respond(retry_page, true, {
    items = {
      { entryId = "entry-new", messages = {} },
      { entryId = "entry-old", messages = { { role = "user", content = {} } } },
    },
    nextCursor = nil,
    hasMore = false,
    leafId = "leaf-b",
  })
  local older = paginated_chat.history_pages[#paginated_chat.history_pages]
  assert(
    older.prepend == true and #older.items == 1 and older.items[1].entryId == "entry-old",
    "history prepend did not suppress a duplicate session entry"
  )
  assert(not runtime.load_older_history(pagination_root), "completed pagination requested a page past the oldest entry")
  runtime.stop(pagination_root)
end

local ok, err = xpcall(run, debug.traceback)
if runtime then
  pcall(runtime.stop, root)
  pcall(runtime.stop, pagination_root)
end
vim.notify = original_notify
package.loaded["pi.ui.chat"] = previous_modules.chat
package.loaded["pi.ui.dialog"] = previous_modules.dialog
package.loaded["pi.client"] = previous_modules.client
package.loaded["pi.runtime"] = previous_modules.runtime
if not ok then
  error(err)
end
print("runtime_spec: ok")
