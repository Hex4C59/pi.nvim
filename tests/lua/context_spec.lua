local context = require("pi.context")

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(vim.fs.joinpath(root, "nested"), "p")

local function make_buffer(path, text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].filetype = "text"
  return bufnr
end

local inside = vim.fs.joinpath(root, "nested", "example.lua")
local outside = root .. "-other/example.lua"
local inside_buf = make_buffer(inside, "local ready = true")
local outside_buf = make_buffer(outside, "outside")

local relpath = vim.fs.relpath
vim.fs.relpath = nil
local ok, err = pcall(function()
  local wrapped = context.range(inside_buf, root, 1, 1, { max_bytes = 1000 })
  assert(wrapped:find("path=\"nested/example.lua\"", 1, true), "Neovim 0.10 relative path fallback failed")

  local external = context.range(outside_buf, root, 1, 1, { max_bytes = 1000 })
  assert(external:find("path=\"" .. outside .. "\"", 1, true), "outside paths must remain absolute")
end)
vim.fs.relpath = relpath
assert(ok, err)

assert(context.is_within_root(root, root), "the project root must contain itself")
assert(
  context.is_within_root(root, vim.fs.joinpath(root, "nested", "..", "file.lua")),
  "normalized child path was rejected"
)
assert(not context.is_within_root(root, root .. "-other/file.lua"), "a sibling prefix was treated as a child")
local tiny_context = context.range(inside_buf, root, 1, 1, { max_bytes = 7, include_diagnostics = false })
assert(#tiny_context <= 7, "an undersized structural budget was exceeded")

local unicode_cases = {
  { text = "AéB", maximum = 2, expected = "A" },
  { text = "A你B", maximum = 3, expected = "A" },
  { text = "A😀B", maximum = 4, expected = "A" },
  { text = "AéB", maximum = 3, expected = "Ae" },
  { text = "ABCDE", maximum = 3, expected = "ABC" },
}
local selection_marker = "[selection truncated by pi.nvim]"
for index, case in ipairs(unicode_cases) do
  local input = case.text .. string.rep("Z", 100)
  local bufnr = make_buffer(vim.fs.joinpath(root, "case-" .. index), input)
  local unbounded = context.range(bufnr, root, 1, 1, { include_diagnostics = false })
  local wrapper_bytes = #unbounded - #input
  local maximum = wrapper_bytes + #selection_marker + 1 + case.maximum
  local wrapped = context.range(bufnr, root, 1, 1, { max_bytes = maximum, include_diagnostics = false })
  local selected = assert(
    wrapped:match("<editor_context[^\n]*>\n(.-)\n%[selection truncated by pi%.nvim%]"),
    "truncation marker is missing"
  )
  assert(selected == case.expected, ("UTF-8 truncation produced %q instead of %q"):format(selected, case.expected))
  assert(#selected <= case.maximum, "UTF-8 truncation exceeded max_bytes")
  assert(#wrapped <= maximum, "complete UTF-8 context exceeded max_bytes")
end

local large_lines = {}
for index = 1, 2000 do
  large_lines[index] = ("line-%04d"):format(index)
end
local large_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(large_buf, vim.fs.joinpath(root, "large.txt"))
vim.api.nvim_buf_set_lines(large_buf, 0, -1, false, large_lines)
local original_get_lines = vim.api.nvim_buf_get_lines
local largest_read = 0
vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
  if bufnr == large_buf then
    largest_read = math.max(largest_read, last - first)
  end
  return original_get_lines(bufnr, first, last, strict)
end
local large_first_line = context.range(large_buf, root, 1, 1, { include_diagnostics = false })
local large_wrapper_bytes = #large_first_line - #large_lines[1]
local large_maximum = large_wrapper_bytes + #selection_marker + 1 + 64
local bounded = context.buffer(large_buf, root, { max_bytes = large_maximum, include_diagnostics = false })
vim.api.nvim_buf_get_lines = original_get_lines
assert(bounded:find("[selection truncated by pi.nvim]", 1, true), "large buffer did not report truncation")
assert(largest_read <= 256, "context limit copied the complete buffer before truncating")
assert(not bounded:find("line-2000", 1, true), "context reader continued after reaching its byte budget")
assert(#bounded <= large_maximum, "complete large-buffer context exceeded max_bytes")

local huge_line_buf = make_buffer(vim.fs.joinpath(root, "huge-line.txt"), string.rep("x", 1024 * 1024))
local huge_line_reads = 0
vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
  if bufnr == huge_line_buf then
    huge_line_reads = huge_line_reads + 1
  end
  return original_get_lines(bufnr, first, last, strict)
end
local huge_line = context.buffer(huge_line_buf, root, { max_bytes = 512, include_diagnostics = false })
vim.api.nvim_buf_get_lines = original_get_lines
assert(huge_line_reads == 0, "a huge single line was copied in full before truncation")
assert(huge_line:find(string.rep("x", 32), 1, true), "bounded single-line prefix is missing")
assert(#huge_line <= 512, "complete huge-line context exceeded max_bytes")

local diagnostic_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(diagnostic_buf, vim.fs.joinpath(root, "diagnostics.lua"))
local diagnostic_lines = {}
for index = 1, 20 do
  diagnostic_lines[index] = ("local value_%d = %d"):format(index, index)
end
vim.api.nvim_buf_set_lines(diagnostic_buf, 0, -1, false, diagnostic_lines)
vim.bo[diagnostic_buf].filetype = "lua"

local namespace = vim.api.nvim_create_namespace("pi.nvim-context-budget-test")
local diagnostic_items = {
  {
    lnum = 0,
    col = 0,
    end_lnum = 4,
    end_col = 1,
    severity = vim.diagnostic.severity.ERROR,
    message = "crossing " .. string.rep("你", 1000),
  },
}
local notable_severities = {
  [2] = vim.diagnostic.severity.INFO,
  [3] = vim.diagnostic.severity.WARN,
  [4] = vim.diagnostic.severity.ERROR,
}
for index = 1, 2000 do
  diagnostic_items[#diagnostic_items + 1] = {
    lnum = 4 + ((index - 1) % 6),
    col = index % 5,
    end_lnum = 4 + ((index - 1) % 6),
    end_col = (index % 5) + 1,
    severity = notable_severities[index] or vim.diagnostic.severity.HINT,
    message = ("diagnostic-%04d "):format(index) .. string.rep("界", 1000),
  }
end
vim.diagnostic.set(namespace, diagnostic_buf, diagnostic_items)

local diagnostic_opts = {
  max_bytes = 4096,
  include_diagnostics = true,
  diagnostics_max_count = 12,
  diagnostic_max_message_bytes = 48,
  diagnostics_max_bytes = 2048,
}
local diagnostic_context = context.range(diagnostic_buf, root, 5, 10, diagnostic_opts)
assert(#diagnostic_context <= diagnostic_opts.max_bytes, "diagnostics escaped the complete context byte limit")
assert(pcall(vim.str_utfindex, diagnostic_context), "diagnostic context contains invalid UTF-8")
assert(
  diagnostic_context == context.range(diagnostic_buf, root, 5, 10, diagnostic_opts),
  "diagnostic ordering is not deterministic"
)

local total, included, omitted, messages_truncated = diagnostic_context:match(
  "<diagnostics total=\"(%d+)\" included=\"(%d+)\" omitted=\"(%d+)\" messages_truncated=\"(%d+)\">"
)
assert(total, "diagnostic omission metadata is missing")
total = tonumber(total)
included = tonumber(included)
omitted = tonumber(omitted)
messages_truncated = tonumber(messages_truncated)
assert(total == #diagnostic_items, "range-intersecting diagnostic was omitted before budgeting")
assert(included > 0 and included <= diagnostic_opts.diagnostics_max_count, "diagnostic count limit was not enforced")
assert(omitted == total - included, "diagnostic omission count is inaccurate")
assert(messages_truncated == included, "truncated diagnostic messages were not reported")

local diagnostic_body = assert(diagnostic_context:match("<diagnostics[^>]*>\n(.-)\n</diagnostics>"))
local rendered_diagnostics = vim.split(diagnostic_body, "\n", { plain = true })
assert(rendered_diagnostics[1]:find("L1:1 [ERROR] crossing ", 1, true), "selected-range intersection lost priority")
local severity_rank = { ERROR = 1, WARN = 2, INFO = 3, HINT = 4, UNKNOWN = 5 }
local previous_rank = 0
local previous_line = 0
local previous_column = 0
for _, line in ipairs(rendered_diagnostics) do
  local line_number, column, severity = line:match("^L(%d+):(%d+) %[(%u+)%] ")
  assert(line_number, "formatted diagnostic position or severity is missing")
  local rank = assert(severity_rank[severity], "unknown rendered diagnostic severity")
  line_number = tonumber(line_number)
  column = tonumber(column)
  assert(rank >= previous_rank, "diagnostic severity ordering is unstable")
  if rank == previous_rank then
    assert(
      line_number > previous_line or (line_number == previous_line and column >= previous_column),
      "diagnostic range ordering is unstable"
    )
  else
    previous_line = 0
    previous_column = 0
  end
  previous_rank = rank
  previous_line = line_number
  previous_column = column
  local message = assert(line:match("%] (.*)$"), "formatted diagnostic message is missing")
  assert(#message <= diagnostic_opts.diagnostic_max_message_bytes, "diagnostic message exceeded its byte limit")
  assert(pcall(vim.str_utfindex, message), "diagnostic message truncation split UTF-8")
end

vim.diagnostic.reset(namespace, diagnostic_buf)

vim.fn.delete(root, "rf")
print("context_spec: ok")
