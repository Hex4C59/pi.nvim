local original_schedule = vim.schedule
local function run()
  local scheduled = {}
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  local dispatch_events = {}
  local Client = require("pi.client").Client
  local unsubscribe_client = Client.new(vim.fn.getcwd() .. "/unsubscribe")
  local unsubscribe_events = 0
  local unsubscribe = unsubscribe_client:on_event(function()
    unsubscribe_events = unsubscribe_events + 1
  end)
  unsubscribe_client:_emit({ type = "before_unsubscribe" })
  assert(unsubscribe_events == 1, "Client listener was not called before unsubscribe")
  assert(unsubscribe(), "Client listener unsubscribe did not remove the listener")
  assert(not unsubscribe(), "Client listener unsubscribe was not idempotent")
  unsubscribe_client:_emit({ type = "after_unsubscribe" })
  assert(unsubscribe_events == 1, "Client listener ran after unsubscribe")

  local client = Client.new(vim.fn.getcwd())
  client:on_event(function(event)
    table.insert(dispatch_events, event.type)
  end)
  client.parser:push("{\"type\":\"first\"}\n{\"type\":\"second\"}\nnot-json\n{\"type\":\"third\"}\n")
  assert(#scheduled == 1, "multiple RPC frames scheduled more than one main-loop dispatch")
  scheduled[1]()
  client.pending.bad = {
    callback = function()
      error("callback failure")
    end,
  }
  client.parser:push("{\"type\":\"response\",\"id\":\"bad\",\"success\":true}\n{\"type\":\"after_failure\"}\n")
  assert(#scheduled == 2, "a second RPC burst did not create exactly one dispatch")
  scheduled[2]()
  vim.schedule = original_schedule
  assert(
    vim.deep_equal(dispatch_events, { "first", "second", "client_error", "third", "client_error", "after_failure" }),
    "batched RPC dispatch changed frame ordering or stopped after a callback failure"
  )

  local matched_client = Client.new(vim.fn.getcwd())
  local matched_response
  matched_client.pending.owned = { callback = function() end }
  matched_client:on_event(function(event)
    matched_response = event
  end)
  matched_client:_handle({ type = "response", id = "owned", success = false, error = "expected" })
  assert(matched_response and matched_response._pi_request_matched, "matched response ownership was not recorded")

  require("pi.config").setup({ output = { rpc_queue_max_messages = 2, rpc_queue_max_bytes = 128 } })
  scheduled = {}
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  local overloaded = Client.new(vim.fn.getcwd())
  assert(overloaded.parser.max_frame_bytes == 128, "Client parser did not inherit the RPC queue byte budget")
  local overload_errors = {}
  overloaded:on_event(function(event)
    if event.type == "client_error" then
      table.insert(overload_errors, event.error)
    end
  end)
  overloaded.parser:push("{\"type\":\"one\"}\n{\"type\":\"two\"}\n{\"type\":\"three\"}\n")
  assert(#scheduled == 1, "RPC overload scheduled redundant drains")
  assert(overloaded.dispatch_count <= 2, "RPC dispatch queue exceeded its message limit")
  scheduled[1]()
  vim.schedule = original_schedule
  assert(#overload_errors == 1, "RPC overload did not report exactly one client error")
  assert(overload_errors[1]:find("dispatch queue exceeded", 1, true), "RPC overload error lost its cause")
  assert(
    overloaded.dispatch_count == 0 and overloaded.dispatch_bytes == 0 and next(overloaded.dispatch_queue) == nil,
    "RPC overload did not release queued payloads"
  )

  local writes = {}
  overloaded.process = {
    is_closing = function()
      return false
    end,
    write = function(_, value)
      table.insert(writes, value)
    end,
  }
  local sent, send_err = overloaded:_raw_send({ type = "prompt", message = string.rep("x", 200) })
  assert(not sent and send_err:find("frame is too large", 1, true), "oversized outbound RPC frame was accepted")
  assert(#writes == 0, "oversized outbound RPC frame reached the Pi process")
  assert(overloaded:_raw_send({ type = "get_state" }), "bounded outbound RPC frame was rejected")
  assert(#writes == 1, "bounded outbound RPC frame was not written exactly once")

  require("pi.config").setup({ output = { rpc_queue_max_messages = 300, rpc_queue_max_bytes = 1024 * 1024 } })
  scheduled = {}
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  local batched = Client.new(vim.fn.getcwd())
  local frames = {}
  for index = 1, 300 do
    frames[index] = vim.json.encode({ type = "batch", index = index })
  end
  batched.parser:push(table.concat(frames, "\n") .. "\n")
  scheduled[1]()
  assert(batched.dispatch_count == 44, "RPC drain did not enforce its batch size")
  for index = 1, 256 do
    assert(batched.dispatch_queue[index] == nil, "RPC drain retained a consumed payload")
  end
  scheduled[2]()
  vim.schedule = original_schedule
  assert(
    batched.dispatch_count == 0 and next(batched.dispatch_queue) == nil,
    "batched RPC drain did not release its queue"
  )
end

local ok, err = xpcall(run, debug.traceback)
vim.schedule = original_schedule
if not ok then
  error(err)
end

print("client_spec: ok")
