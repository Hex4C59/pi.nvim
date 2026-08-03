local renderer = require("pi.ui.render")
local text = require("pi.ui.render.text")

assert(renderer.format_elapsed(3.7) == "3.7s", "live sub-minute duration lost its precision")
assert(renderer.format_elapsed(357) == "5m 57s", "live duration must switch to minutes")
assert(renderer.format_elapsed(3723) == "1h 2m 3s", "live duration must switch to hours")
assert(renderer.format_duration(357000) == "5m 57s", "recorded duration must switch to minutes")
assert(renderer.format_duration(3723000) == "1h 2m 3s", "recorded duration must switch to hours")
assert(renderer.format_duration(nil) == nil, "nil duration no longer means unavailable")

local split_cases = {
  { nil, {} },
  { "", {} },
  { "one", { "one" } },
  { "one\ntwo", { "one", "two" } },
  { "one\r\ntwo", { "one", "two" } },
  { "one\rtwo", { "one", "two" } },
  { "one\n", { "one", "" } },
  { "one\n\ntwo", { "one", "", "two" } },
  { "界面\n正常", { "界面", "正常" } },
  { "a\226\128\168b\226\128\169c", { "a\226\128\168b\226\128\169c" } },
}
for _, case in ipairs(split_cases) do
  assert(vim.deep_equal(text.split_lines(case[1]), case[2]), "split_lines boundary changed")
end

local result = {
  content = {
    { type = "text", text = "first" },
    { type = "image", data = "ignored" },
    { type = "text", text = "second" },
    { type = "omitted", reason = "image_limit" },
    { type = "text" },
  },
}
local authoritative = vim.deepcopy(result)
assert(text.result_text(nil) == "")
assert(text.result_text({ content = {} }) == "")
assert(text.result_text({ content = { { type = "image" } } }) == "")
assert(text.result_text(result) == "first\nsecond\n[Image omitted: payload exceeded the client tool output limit]")
assert(vim.deep_equal(result, authoritative), "result_text mutated structured result content")

local durations = {
  { 0, "0ms" },
  { 999, "999ms" },
  { 1000, "1.0s" },
  { 9999, "10.0s" },
  { 60000, "1m 0s" },
  { 3600000, "1h 0m 0s" },
  { -1, "-1ms" },
}
for _, case in ipairs(durations) do
  assert(text.format_duration(case[1]) == case[2], "duration boundary changed")
end
local elapsed = {
  { -1, "0.0s" },
  { 0, "0.0s" },
  { 1, "1.0s" },
  { 9.99, "10.0s" },
  { 10, "10s" },
  { 59.5, "1m 0s" },
  { 60, "1m 0s" },
  { 3600, "1h 0m 0s" },
  { "invalid", "0.0s" },
}
for _, case in ipairs(elapsed) do
  assert(text.format_elapsed(case[1]) == case[2], "elapsed-time boundary changed")
end
local bytes = {
  { -1, "0 bytes" },
  { 0, "0 bytes" },
  { 1023, "1023 bytes" },
  { 1024, "1.0 KiB" },
  { 1024 * 1024 - 1, "1024.0 KiB" },
  { 1024 * 1024, "1.0 MiB" },
}
for _, case in ipairs(bytes) do
  assert(text.format_bytes(case[1]) == case[2], "byte-format boundary changed")
end

local truncations = {
  { value = "fits", width = 5, expected = "fits" },
  { value = "one-cell", width = 7, expected = "one-..." },
  { value = "界面内容", width = 7, expected = "界面..." },
  { value = "a\204\129bcdef", width = 6 },
  { value = "first\nsecond", width = 12 },
  { value = "anything", width = 1, expected = "." },
  { value = "anything", width = 3, expected = "..." },
}
for _, case in ipairs(truncations) do
  local truncated = text.truncate_display(case.value, case.width)
  assert(vim.api.nvim_strwidth(truncated) <= case.width, "display truncation exceeded its width")
  vim.str_utfindex(truncated)
  assert(not truncated:find("[\r\n]"), "display truncation retained an embedded newline")
  if case.expected then
    assert(truncated == case.expected, "display truncation boundary changed")
  end
end

print("render_text_spec: ok")
