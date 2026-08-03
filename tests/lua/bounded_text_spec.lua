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
assert(long_line:stats().copied_bytes <= 64, "large single delta copied its discarded prefix")

local split_utf8 = buffer({ max_bytes = 1024, max_lines = 1024, max_chunks = 16 })
split_utf8:append(string.rep("中", 400))
assert(pcall(vim.str_utfindex, split_utf8:text()), "fixed-size block split broke a UTF-8 code point")
assert(#split_utf8:text() <= 1024, "split UTF-8 stream exceeded its byte limit")

local one_chunk = buffer({ max_bytes = 64, max_lines = 64, max_chunks = 1 })
for _ = 1, 100 do
  one_chunk:append("x")
end
assert(one_chunk:text() == string.rep("x", 64), "single-chunk mode changed retained tail semantics")
assert(one_chunk:stats().chunks == 1, "single-chunk mode exceeded max_chunks")

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

local function small_delta_copy_work(window)
  local stream = buffer({ max_bytes = window, max_lines = 1000000, max_chunks = 256 })
  local appended = 100000
  for _ = 1, appended do
    stream:append("x")
  end
  local stream_stats = stream:stats()
  assert(stream_stats.retained_bytes == window, "complexity fixture retained the wrong byte window")
  assert(stream_stats.omitted_bytes == appended - window, "complexity fixture omission accounting changed")
  assert(stream_stats.chunks <= 256, "complexity fixture exceeded max_chunks")
  assert(stream_stats.copied_bytes <= appended * 24, "small deltas caused superlinear retained-window copying")
  return stream_stats.copied_bytes
end

local small_window_work = small_delta_copy_work(1024)
local large_window_work = small_delta_copy_work(64 * 1024)
assert(
  large_window_work <= small_window_work * 2,
  "small-delta copy work scaled in proportion to the 64x larger retained window"
)

local empty = buffer()
empty:append("")
assert(empty:stats().chunks == 0, "empty delta created a chunk")

print("bounded_text_spec: ok")
