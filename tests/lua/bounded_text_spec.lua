local BoundedText = require("pi.bounded_text").BoundedText

local function buffer(opts)
  return BoundedText.new(vim.tbl_extend("force", { max_bytes = 64, max_lines = 10, max_chunks = 4 }, opts or {}))
end

local small = buffer()
small:append("hello\nworld")
assert(small:text() == "hello\nworld", "small text changed")
assert(small:stats().retained_bytes == 11 and not small:stats().truncated, "small text stats are wrong")

local bytes = buffer({ max_bytes = 5 })
bytes:append("0123456789")
assert(bytes:text() == "56789", "byte limit did not retain the tail")
assert(bytes:stats().omitted_bytes == 5, "byte omission count is wrong")

local lines = buffer({ max_lines = 2 })
lines:append("one\ntwo\nthree\nfour")
assert(lines:text() == "three\nfour", "line limit did not retain the tail")
assert(lines:stats().retained_lines == 2 and lines:stats().omitted_lines == 2, "line stats are wrong")

local strict = buffer({ max_bytes = 8, max_lines = 2 })
strict:append("one\ntwo\nthree")
assert(#strict:text() <= 8 and strict:stats().retained_lines <= 2, "combined limits were not enforced")

local utf8 = buffer({ max_bytes = 9 })
utf8:append("中文🙂abc")
local ok = pcall(vim.str_utfindex, utf8:text())
assert(ok, "UTF-8 tail begins inside a code point")
assert(#utf8:text() <= 9, "UTF-8 trimming exceeded the byte limit")

local long_line = buffer({ max_bytes = 32 })
long_line:append(string.rep("x", 100000))
assert(#long_line:text() == 32, "large single line escaped the byte limit")

local many = buffer({ max_bytes = 1024, max_lines = 1024, max_chunks = 16 })
local last_omitted = 0
for _ = 1, 100000 do
  many:append("x")
  local stats = many:stats()
  assert(stats.omitted_bytes >= last_omitted, "omitted bytes decreased")
  last_omitted = stats.omitted_bytes
end
local stats = many:stats()
assert(
  stats.retained_bytes <= 1024 and stats.retained_lines <= 1024 and stats.chunks <= 16,
  "stress state is unbounded"
)
assert(stats.omitted_bytes == 100000 - stats.retained_bytes, "stress omission count is inaccurate")

local empty = buffer()
empty:append("")
assert(empty:stats().chunks == 0, "empty delta created a chunk")

print("bounded_text_spec: ok")
