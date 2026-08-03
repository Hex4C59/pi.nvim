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

local unicode_cases = {
  { text = "AéB", maximum = 2, expected = "A" },
  { text = "A你B", maximum = 3, expected = "A" },
  { text = "A😀B", maximum = 4, expected = "A" },
  { text = "AéB", maximum = 3, expected = "Ae" },
  { text = "ABCDE", maximum = 3, expected = "ABC" },
}
for index, case in ipairs(unicode_cases) do
  local bufnr = make_buffer(vim.fs.joinpath(root, "case-" .. index), case.text)
  local wrapped = context.range(bufnr, root, 1, 1, { max_bytes = case.maximum })
  local selected = assert(
    wrapped:match("<editor_context[^\n]*>\n(.-)\n%[selection truncated by pi%.nvim%]"),
    "truncation marker is missing"
  )
  assert(selected == case.expected, ("UTF-8 truncation produced %q instead of %q"):format(selected, case.expected))
  assert(#selected <= case.maximum, "UTF-8 truncation exceeded max_bytes")
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
local bounded = context.buffer(large_buf, root, { max_bytes = 64 })
vim.api.nvim_buf_get_lines = original_get_lines
assert(bounded:find("[selection truncated by pi.nvim]", 1, true), "large buffer did not report truncation")
assert(largest_read <= 256, "context limit copied the complete buffer before truncating")
assert(not bounded:find("line-2000", 1, true), "context reader continued after reaching its byte budget")

local huge_line_buf = make_buffer(vim.fs.joinpath(root, "huge-line.txt"), string.rep("x", 1024 * 1024))
local huge_line_reads = 0
vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
  if bufnr == huge_line_buf then
    huge_line_reads = huge_line_reads + 1
  end
  return original_get_lines(bufnr, first, last, strict)
end
local huge_line = context.buffer(huge_line_buf, root, { max_bytes = 32 })
vim.api.nvim_buf_get_lines = original_get_lines
assert(huge_line_reads == 0, "a huge single line was copied in full before truncation")
assert(huge_line:find(string.rep("x", 32), 1, true), "bounded single-line prefix is missing")

vim.fn.delete(root, "rf")
print("context_spec: ok")
