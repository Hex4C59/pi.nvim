local base = vim.fn.tempname()
local first = vim.fs.joinpath(base, "first")
local second = vim.fs.joinpath(base, "second")
vim.fn.mkdir(first, "p")
vim.fn.mkdir(second, "p")

local function write_session(path, cwd)
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  local line = vim.json.encode({ type = "session", version = 3, id = "test", timestamp = "now", cwd = cwd }) .. "\n"
  assert(vim.uv.fs_write(fd, line, 0))
  assert(vim.uv.fs_close(fd))
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
assert(#requests == 1 and requests[1].name == "switch_session", "same-project resume did not send exactly one request")
assert(
  requests[1].payload.sessionPath == assert(vim.uv.fs_realpath(same_path)),
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

vim.fn.delete(base, "rf")
print("session_spec: ok")
