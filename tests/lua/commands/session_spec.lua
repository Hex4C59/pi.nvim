local base = vim.fn.tempname()
local previous_runtime = package.loaded["pi.runtime"]
local previous_session_commands = package.loaded["pi.commands.session"]
local previous_select = vim.ui.select
local previous_input = vim.ui.input
local previous_columns = vim.o.columns
local function run()
  local first = vim.fs.joinpath(base, "first")
  local second = vim.fs.joinpath(base, "second")
  vim.fn.mkdir(first, "p")
  vim.fn.mkdir(second, "p")

  local function write_session(path, cwd)
    local fd = assert(vim.uv.fs_open(path, "w", 420), "session command fixture file could not be opened")
    local line = vim.json.encode({ type = "session", version = 3, id = "test", timestamp = "now", cwd = cwd }) .. "\n"
    local written = vim.uv.fs_write(fd, line, 0)
    local closed = vim.uv.fs_close(fd)
    assert(written == #line, "session command fixture content was not written completely")
    assert(closed, "session command fixture descriptor could not be closed")
  end

  local same_path = vim.fs.joinpath(base, "same.jsonl")
  local other_path = vim.fs.joinpath(base, "other.jsonl")
  write_session(same_path, first)
  write_session(other_path, second)

  local requests = {}
  local reloads = 0
  local errors = {}
  local next_result = { success = true, data = { cancelled = false } }
  local action_generation = 0
  local picker_options
  local picker = {
    closed = false,
    append = function(self, sessions, next_cursor)
      self.appended = sessions
      self.next_cursor = next_cursor
    end,
    set_error = function(self, message)
      self.error = message
    end,
  }
  local client = {
    root = first,
    session = { rpcCapabilities = { "list_sessions", "navigate_tree" } },
    request = function(_, name, payload, callback)
      table.insert(requests, { name = name, payload = payload })
      callback(next_result.success, next_result.data, next_result.err)
    end,
  }

  package.loaded["pi.runtime"] = {
    get_client = function()
      return client
    end,
    reload_session = function()
      reloads = reloads + 1
      action_generation = action_generation + 1
    end,
    notify_error = function(message)
      table.insert(errors, message)
    end,
    begin_session_action = function()
      action_generation = action_generation + 1
      return action_generation
    end,
    session_action_current = function(_, action)
      return action == action_generation
    end,
    chat_for = function()
      return {
        set_input = function(_, value)
          client.input = value
        end,
      }
    end,
    open_session_picker = function(options)
      picker_options = options
      return picker
    end,
  }
  package.loaded["pi.commands.session"] = nil
  local commands = require("pi.commands.session")

  commands.resume(other_path, first)
  assert(#requests == 0, "cross-project resume sent switch_session")
  assert(
    #errors == 1 and errors[1]:find(first, 1, true) and errors[1]:find(second, 1, true),
    "root mismatch was not shown"
  )

  commands.resume(same_path, first)
  assert(
    #requests == 1 and requests[1].name == "switch_session",
    "same-project resume did not send exactly one request"
  )
  assert(
    requests[1].payload.sessionPath
      == assert(vim.uv.fs_realpath(same_path), "same-root session fixture did not resolve canonically"),
    "resume did not use canonical session path"
  )
  assert(reloads == 1, "successful resume did not reload the session")

  next_result = { success = true, data = { cancelled = true } }
  commands.resume(same_path, first)
  assert(reloads == 1, "cancelled resume cleared or reloaded the active session")

  next_result = { success = false, data = nil, err = "fixture failure" }
  commands.resume(same_path, first)
  assert(reloads == 1, "failed resume cleared or reloaded the active session")
  assert(errors[#errors] == "fixture failure", "RPC resume failure was not reported")

  requests = {}
  next_result = {
    success = true,
    data = {
      sessions = { { path = same_path, cwd = first, name = "same project" } },
      nextCursor = "next-page",
    },
  }
  commands.resume(nil, first)
  assert(#requests == 1 and requests[1].name == "list_sessions", "resume picker did not request sessions")
  assert(picker_options and picker_options.next_cursor == "next-page", "resume picker lost the continuation cursor")
  next_result = { success = true, data = { sessions = { { path = "page-2", cwd = first } } } }
  picker_options.on_more("next-page", picker)
  assert(requests[#requests].payload.cursor == "next-page", "resume pagination did not return the opaque cursor")
  assert(picker.appended[1].path == "page-2", "resume pagination did not append the next authoritative page")

  next_result = { success = true, data = { cancelled = false } }
  picker_options.on_select({ path = same_path, cwd = first })
  assert(requests[#requests].name == "switch_session", "session selection did not request an authoritative switch")
  assert(reloads == 2, "session picker switch did not reload after success")

  requests = {}
  next_result = { success = true, data = { sessions = { { path = other_path, cwd = second } } } }
  commands.resume(nil, first)
  picker_options.on_select({ path = other_path, cwd = second })
  assert(#requests == 1 and requests[1].name == "list_sessions", "cross-root picker selection sent switch_session")
  assert(errors[#errors]:find("Cross%-project session resume is blocked"), "picker root mismatch was not shown")

  requests = {}
  next_result = { success = true, data = { sessions = { { path = same_path, cwd = first } } } }
  commands.resume(nil, first)
  local stale_options = picker_options
  commands.resume(nil, first)
  stale_options.on_select({ path = same_path, cwd = first })
  local switch_count = 0
  for _, request in ipairs(requests) do
    if request.name == "switch_session" then
      switch_count = switch_count + 1
    end
  end
  assert(switch_count == 0, "a stale resume picker switched the active session")

  requests = {}
  client.session.rpcCapabilities = {}
  local prompted_for_path = false
  vim.ui.input = function(_, callback)
    prompted_for_path = true
    callback(nil)
  end
  commands.resume(nil, first)
  assert(prompted_for_path, "older Pi fallback did not offer exact-path resume")
  assert(#requests == 0, "older Pi fallback sent the unsupported list_sessions command")
  client.session.rpcCapabilities = { "list_sessions", "navigate_tree" }

  local selected_items
  next_result = {
    success = true,
    data = {
      leafId = "leaf",
      tree = {
        {
          entry = {
            id = "leaf",
            type = "message",
            message = { role = "user", content = string.rep("中文🙂e\204\129", 20) },
          },
          children = {},
        },
      },
    },
  }
  vim.o.columns = 24
  vim.ui.select = function(items, _, callback)
    selected_items = items
    callback(nil)
  end
  commands.tree(first)
  assert(#selected_items == 1, "tree picker did not receive the authoritative node")
  local label = selected_items[1].label
  assert(pcall(vim.str_utfindex, label), "tree preview split a UTF-8 code point")
  assert(vim.fn.strdisplaywidth(label) <= 22, "tree preview exceeded the narrow picker budget")
  assert(label:find(" ← active", 1, true), "narrow tree preview lost the active-leaf marker")

  local select_step = 0
  next_result = {
    success = true,
    data = {
      leafId = "current",
      tree = {
        {
          entry = {
            id = "target",
            type = "message",
            message = { role = "assistant", content = "reply" },
          },
          children = {},
        },
      },
    },
  }
  vim.ui.select = function(items, _, callback)
    select_step = select_step + 1
    if select_step == 1 then
      callback(items[1])
    else
      next_result = { success = true, data = { cancelled = false, leafId = "target" } }
      callback("Navigate here")
    end
  end
  local reloads_before_navigation = reloads
  commands.tree(first)
  assert(requests[#requests].name == "navigate_tree", "tree action did not use the structured navigation RPC")
  assert(requests[#requests].payload.entryId == "target", "tree navigation did not preserve the structured entry id")
  assert(reloads == reloads_before_navigation + 1, "successful tree navigation did not reload authoritative state")

  local tree_selections = {}
  next_result = {
    success = true,
    data = {
      leafId = "current",
      tree = {
        {
          entry = { id = "stale-target", type = "message", message = { role = "assistant", content = "old" } },
          children = {},
        },
      },
    },
  }
  vim.ui.select = function(items, _, callback)
    table.insert(tree_selections, { items = items, callback = callback })
  end
  commands.tree(first)
  commands.tree(first)
  assert(#tree_selections == 2, "overlapping tree reads did not open both test selectors")
  tree_selections[1].callback(tree_selections[1].items[1])
  assert(#tree_selections == 2, "a stale tree selector opened an action menu")
end

local ok, err = xpcall(run, debug.traceback)
vim.ui.select = previous_select
vim.ui.input = previous_input
vim.o.columns = previous_columns
vim.fn.delete(base, "rf")
package.loaded["pi.runtime"] = previous_runtime
package.loaded["pi.commands.session"] = previous_session_commands
if not ok then
  error(err)
end
print("session_spec: ok")
