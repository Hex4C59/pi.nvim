local session_file = require("pi.session_file")

local base = vim.fn.tempname()
local function run()
  local first = vim.fs.joinpath(base, "app")
  local sibling = vim.fs.joinpath(base, "app-other")
  vim.fn.mkdir(first, "p")
  vim.fn.mkdir(sibling, "p")

  local function write(path, content)
    local fd = assert(vim.uv.fs_open(path, "w", 420), "session fixture file could not be opened")
    local written = vim.uv.fs_write(fd, content, 0)
    local closed = vim.uv.fs_close(fd)
    assert(written == #content, "session fixture content was not written completely")
    assert(closed, "session fixture file descriptor could not be closed")
  end

  local function session(path, cwd, ending)
    write(path, vim.json.encode({ type = "session", version = 3, id = "test", timestamp = "now", cwd = cwd }) .. ending)
  end

  local valid = vim.fs.joinpath(base, "valid.jsonl")
  session(valid, first, "\n")
  local header = assert(session_file.read_header(valid), "valid session fixture did not produce a header")
  assert(header.cwd == first and header.version == 3, "valid v3 header was not parsed")
  assert(header.path == assert(vim.uv.fs_realpath(valid)), "session file path was not canonicalized")

  local crlf = vim.fs.joinpath(base, "crlf.jsonl")
  session(crlf, first, "\r\n")
  assert(session_file.read_header(crlf), "CRLF session header was rejected")

  local cases = {
    malformed = "{\n",
    wrong_type = vim.json.encode({ type = "message", version = 3, cwd = first }) .. "\n",
    missing_cwd = vim.json.encode({ type = "session", version = 3 }) .. "\n",
    empty_cwd = vim.json.encode({ type = "session", version = 3, cwd = "" }) .. "\n",
    missing_version = vim.json.encode({ type = "session", cwd = first }) .. "\n",
    missing_newline = vim.json.encode({ type = "session", version = 3, cwd = first }),
    large = string.rep("x", 65537) .. "\n",
  }
  for name, content in pairs(cases) do
    local path = vim.fs.joinpath(base, name .. ".jsonl")
    write(path, content)
    local result = session_file.read_header(path)
    assert(result == nil, name .. " session header was accepted")
  end

  assert(session_file.read_header(vim.fs.joinpath(base, "missing.jsonl")) == nil, "missing session file was accepted")
  assert(session_file.read_header(base) == nil, "directory was accepted as a session file")

  local same, roots = session_file.same_root(first, first .. "/.")
  assert(same and roots.current == roots.session, "equivalent real paths did not compare equal")
  assert(not session_file.same_root(first, sibling), "prefix-sibling roots compared equal")
  assert(not session_file.same_root(first, vim.fs.joinpath(base, "missing-root")), "missing cwd was accepted")
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(base, "rf")
if not ok then
  error(err)
end
print("session_file_spec: ok")
