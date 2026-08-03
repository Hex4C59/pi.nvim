local base = vim.fn.tempname()
local previous_runtime = package.loaded["pi.runtime"]
local previous_session_commands = package.loaded["pi.commands.session"]
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
  local client = {
    root = first,
    session = {},
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
    end,
    notify_error = function(message)
      table.insert(errors, message)
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
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(base, "rf")
package.loaded["pi.runtime"] = previous_runtime
package.loaded["pi.commands.session"] = previous_session_commands
if not ok then
  error(err)
end
print("session_spec: ok")
