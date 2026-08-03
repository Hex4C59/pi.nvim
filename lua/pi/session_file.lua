local M = {}

local DEFAULT_MAX_HEADER_BYTES = 64 * 1024
local CURRENT_SESSION_VERSION = 3

local function close_fd(fd)
  if fd then
    pcall(vim.uv.fs_close, fd)
  end
end

local function failure(path, reason)
  return nil, ("Unable to read Pi session header %s: %s"):format(path, reason)
end

function M.read_header(path, opts)
  opts = opts or {}
  local maximum = opts.max_header_bytes or DEFAULT_MAX_HEADER_BYTES
  if type(path) ~= "string" or vim.trim(path) == "" then
    return failure(tostring(path or ""), "path is missing")
  end
  if type(maximum) ~= "number" or maximum < 1 then
    return failure(path, "invalid header byte limit")
  end

  local expanded = vim.fn.expand(vim.trim(path))
  local canonical, realpath_err = vim.uv.fs_realpath(expanded)
  if not canonical then
    return failure(expanded, realpath_err or "file does not exist")
  end
  local stat, stat_err = vim.uv.fs_stat(canonical)
  if not stat or stat.type ~= "file" then
    return failure(canonical, stat_err or "path is not a regular file")
  end

  local fd, open_err = vim.uv.fs_open(canonical, "r", 438)
  if not fd then
    return failure(canonical, open_err or "unable to open file")
  end
  local chunk, read_err = vim.uv.fs_read(fd, maximum + 1, 0)
  close_fd(fd)
  if not chunk then
    return failure(canonical, read_err or "unable to read file")
  end

  local newline = chunk:find("\n", 1, true)
  if not newline then
    if #chunk > maximum or stat.size > maximum then
      return failure(canonical, "header is too large")
    end
    return failure(canonical, "header must end with a newline")
  end
  if newline - 1 > maximum then
    return failure(canonical, "header is too large")
  end

  local line = chunk:sub(1, newline - 1):gsub("\r$", "")
  local ok, header = pcall(vim.json.decode, line)
  if not ok or type(header) ~= "table" then
    return failure(canonical, "invalid JSON")
  end
  if header.type ~= "session" then
    return failure(canonical, "first record is not a session header")
  end
  if type(header.cwd) ~= "string" or vim.trim(header.cwd) == "" then
    return failure(canonical, "session cwd is missing")
  end
  if
    type(header.version) ~= "number"
    or header.version % 1 ~= 0
    or header.version < 1
    or header.version > CURRENT_SESSION_VERSION
  then
    return failure(canonical, "unsupported session version")
  end
  header.path = canonical
  return header
end

function M.same_root(client_root, session_root)
  local client_canonical, client_err = vim.uv.fs_realpath(client_root)
  if not client_canonical then
    return false, ("Unable to verify current project root %s: %s"):format(client_root, client_err or "not found")
  end
  local session_canonical, session_err = vim.uv.fs_realpath(session_root)
  if not session_canonical then
    return false, ("Unable to verify session project root %s: %s"):format(session_root, session_err or "not found")
  end
  local roots = { current = client_canonical, session = session_canonical }
  return client_canonical == session_canonical, roots
end

return M
